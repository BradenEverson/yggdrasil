//! Root protocol implementation

const std = @import("std");

pub const NetworkPacket = @import("network_packet.zig");
pub const AppPacket = @import("app_packet.zig");
pub const MessageQueue = @import("message_queue.zig");

pub const routing = @import("routing.zig");
pub const link_layer = @import("link_layer.zig");
pub const ForwardingTable = routing.ForwardingTable;

/// Errors that are common to most APIs and
/// communication methods
pub const YggdrasilError = error{};
const LARGEST_PACKET_SIZE: usize = 240;

/// Scratch space for serializing an outgoing packet: header + max payload + crc
const TX_BUFFER_SIZE: usize = 256;

const NETWORK_HEADER_LEN: usize = 7;

/// The states we can be in while reading
/// from the incoming stream
pub const ParseState = enum {
    awaiting_header,

    awaiting_from_msb,
    awaiting_from_lsb,

    awaiting_to_msb,
    awaiting_to_lsb,

    awaiting_flags,

    awaiting_len,

    reading_payload,

    awaiting_crc_msb,
    awaiting_crc_lsb,
};

/// The middleware struct between a high level app layer
/// and whatever communication method there is at the
/// physical level (UART, LoRa, whateva)
pub const Yggdrasil = struct {
    /// A blocking consume function that reads
    /// a slice of bytes from a stream source
    /// (UART, LoRa, BLE, etc)
    read_bytes_fn: *const fn (buf: []u8) YggdrasilError![]u8,
    write_bytes_fn: *const fn (buf: []u8) YggdrasilError!void,

    address: u16 = 0,

    outgoing_packets: MessageQueue = .{},
    forwarding_table: ForwardingTable = .{},

    state: ParseState = .awaiting_header,
    cursor: usize = 0,

    buffer: []u8 = undefined,
    packet_buffer: [LARGEST_PACKET_SIZE]u8 = undefined,

    result_cb: *const fn (packet: NetworkPacket) void,

    building_packet: NetworkPacket = .{},

    /// scheduling mechanism to wrap around all neighbors' message queues
    pub fn requestWrite(ygg: *Yggdrasil) YggdrasilError!bool {
        const mq = &ygg.outgoing_packets;
        const ft = &ygg.forwarding_table;

        for (ft.output_map[0..ft.num_registered_output_map]) |*neighbor| {
            if (!neighbor.ack_pending or mq.txBuffer(neighbor.mq_idx) != null)
                continue;

            var ack = NetworkPacket{
                .from = ygg.address,
                .to = neighbor.addr,
                .sn = neighbor.sn,
                .nesn = neighbor.nesn,
            };
            neighbor.ack_pending = false;
            try ygg.writePacket(&ack);
            return true;
        }

        const slot = mq.roundRobinTx() orelse return false;
        const packet = mq.txBuffer(slot).?;

        const neighbor = if (packet.broadcast) null else ft.neighborBySlot(slot);
        if (neighbor) |n| {
            packet.sn = n.sn;
            packet.nesn = n.nesn;
            n.ack_pending = false;
        }

        try ygg.writePacket(packet);

        if (neighbor == null)
            mq.ackTxBuffer(slot);

        return true;
    }

    fn writePacket(ygg: *Yggdrasil, packet: *NetworkPacket) YggdrasilError!void {
        var buf: [TX_BUFFER_SIZE]u8 = undefined;
        packet.crc = null;
        try ygg.write_bytes_fn(packet.toBuffer(&buf));
    }

    /// Handles network level packets that are relevant to routing tables, forwarding,
    /// etc. Passes through most (maybe all?) messages to the app level callback as well
    pub fn handle_network_packet(ygg: *Yggdrasil, packet: NetworkPacket) void {
        if (ygg.address == packet.to) {
            // Message is for us, need to verify at the link layer level if
            // our last message was sent and if this is a new packet

            if (ygg.forwarding_table.neighborByAddr(packet.from)) |neighbor| {
                if (link_layer.isLinkOnly(&packet)) {
                    link_layer.processAck(ygg, neighbor, packet.nesn);
                    return;
                }

                if (!link_layer.linkLayerProcess(ygg, neighbor, packet.sn, packet.nesn))
                    return;
            }

            ygg.result_cb(packet);
        } else if (packet.broadcast) {
            // Broadcast packets do not carry link layer information, since they are sent to everybody!
        } else {
            // Packet was forwarded to us along a route, check if we can carry on the routing
        }
    }

    /// Superloop that will constantly poll the provided read function and feed it to
    /// a state machine for parsing out Yggdrasil packets. Performs a quick verification
    /// of the CRC, and if successful passes the message to the callback :D
    pub fn readStream(ygg: *Yggdrasil) YggdrasilError!void {
        const bytes = try ygg.read_bytes_fn(ygg.buffer);

        for (bytes) |byte| {
            if (ygg.readByte(byte)) |packet| {
                if (NetworkPacket.CRC.validateCRC(
                    ygg.packet_buffer[0 .. ygg.building_packet.len + NETWORK_HEADER_LEN],
                    ygg.building_packet.crc.?,
                )) {
                    ygg.handle_network_packet(packet);
                } else {
                    // TODO!!!!!!!!!!!!
                    // Call error callback!
                    //
                    // The application from here can
                    // choose to send a nack, shouldn't
                    // be our decision here
                }
            }
        }
    }

    pub fn readByte(ygg: *Yggdrasil, byte: u8) ?NetworkPacket {
        ygg.packet_buffer[ygg.cursor] = byte;
        ygg.cursor += 1;

        switch (ygg.state) {
            .awaiting_header => {
                if (byte == NetworkPacket.HEADER) {
                    ygg.state = .awaiting_from_msb;
                }
            },

            .awaiting_from_msb => {
                ygg.building_packet.from = 0;
                ygg.building_packet.from |= byte;
                ygg.building_packet.from <<= 8;
                ygg.state = .awaiting_from_lsb;
            },
            .awaiting_from_lsb => {
                ygg.building_packet.from |= byte;
                ygg.state = .awaiting_to_msb;
            },

            .awaiting_to_msb => {
                ygg.building_packet.to = 0;
                ygg.building_packet.to |= byte;
                ygg.building_packet.to <<= 8;
                ygg.state = .awaiting_to_lsb;
            },
            .awaiting_to_lsb => {
                ygg.building_packet.to |= byte;
                ygg.state = .awaiting_flags;
            },

            .awaiting_flags => {
                ygg.building_packet.parseFlags(byte);
                ygg.state = .awaiting_len;
            },

            .awaiting_len => {
                ygg.building_packet.len = byte;

                if (ygg.building_packet.len == 0) {
                    ygg.state = .awaiting_crc_msb;
                } else {
                    ygg.state = .reading_payload;
                }
            },
            .reading_payload => {
                ygg.building_packet.payload[ygg.cursor - NETWORK_HEADER_LEN] = byte;
                if (ygg.cursor == ygg.building_packet.len + NETWORK_HEADER_LEN) {
                    ygg.state = .awaiting_crc_msb;
                }
            },

            .awaiting_crc_msb => {
                ygg.building_packet.crc = 0;
                ygg.building_packet.crc.? |= byte;
                ygg.building_packet.crc.? <<= 8;
                ygg.state = .awaiting_crc_lsb;
            },
            .awaiting_crc_lsb => {
                ygg.building_packet.crc.? |= byte;

                ygg.state = .awaiting_header;
                ygg.cursor = 0;
                return ygg.building_packet;
            },
        }

        return null;
    }
};

test "Simple packet parsing" {
    var buffer: [64]u8 = undefined;

    const Runtime = struct {
        var seen: bool = false;

        fn packetEvent(packet: NetworkPacket) void {
            _ = packet;
            seen = true;
        }

        fn read(buf: []u8) YggdrasilError![]u8 {
            var nop = NetworkPacket{};

            const packet = nop.toBuffer(buf);

            return packet;
        }

        fn write(buf: []u8) YggdrasilError!void {
            _ = buf;
        }
    };

    var ygg = Yggdrasil{
        .read_bytes_fn = Runtime.read,
        .write_bytes_fn = Runtime.write,
        .result_cb = Runtime.packetEvent,
        .buffer = &buffer,
    };

    try ygg.readStream();
    try std.testing.expect(Runtime.seen);
}

test {
    _ = @import("network_packet.zig");
    _ = @import("app_packet.zig");
    _ = @import("routing.zig");
    _ = @import("message_queue.zig");
    _ = @import("link_layer.zig");
}
