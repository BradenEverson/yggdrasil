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

pub const SendError = error{ NoRoute, PayloadTooLarge } || MessageQueue.PushError;
pub const NeighborError = ForwardingTable.Error;

/// The states we can be in while reading
/// from the incoming stream
pub const ParseState = enum {
    awaiting_header,

    awaiting_from_msb,
    awaiting_from_lsb,

    awaiting_to_msb,
    awaiting_to_lsb,

    awaiting_origin_msb,
    awaiting_origin_lsb,

    awaiting_dest_msb,
    awaiting_dest_lsb,

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
                .origin = ygg.address,
                .dest = neighbor.addr,
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
            packet.from = ygg.address;
            packet.to = n.addr;
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

    pub fn registerNeighbor(ygg: *Yggdrasil, addr: u16, slot: usize) NeighborError!*routing.MessageQueueMap {
        const neighbor = try ygg.forwarding_table.registerNeighbor(addr, slot);

        const mq = &ygg.outgoing_packets;
        if (slot + 1 > mq.registered_nodes)
            mq.registered_nodes = slot + 1;

        return neighbor;
    }

    pub fn learnNeighbor(ygg: *Yggdrasil, addr: u16) NeighborError!*routing.MessageQueueMap {
        const ft = &ygg.forwarding_table;

        if (ft.neighborByAddr(addr)) |existing|
            return existing;

        const slot = ft.freeSlot() orelse return error.TooManyNeighbors;
        return ygg.registerNeighbor(addr, slot);
    }

    pub fn send(ygg: *Yggdrasil, dest: u16, payload: []const u8, priority: u8) SendError!void {
        const hop = ygg.forwarding_table.nextHop(dest) orelse return error.NoRoute;

        var packet = NetworkPacket{
            .from = ygg.address,
            .to = hop.addr,
            .origin = ygg.address,
            .dest = dest,
        };
        try packet.setPayload(payload);

        try ygg.outgoing_packets.pushMessage(hop.mq_idx, packet, priority);
    }

    pub fn sendApp(ygg: *Yggdrasil, dest: u16, app: AppPacket, priority: u8) SendError!void {
        var buf: [NetworkPacket.MAX_PAYLOAD_SIZE]u8 = undefined;
        const bytes = app.write(&buf) catch return error.PayloadTooLarge;
        try ygg.send(dest, bytes, priority);
    }

    pub fn sayHello(ygg: *Yggdrasil) YggdrasilError!void {
        const ft = &ygg.forwarding_table;
        for (ft.output_map[0..ft.num_registered_output_map]) |*neighbor|
            resetLink(neighbor);

        var packet = NetworkPacket{
            .from = ygg.address,
            .to = NetworkPacket.BROADCAST_ADDR,
            .origin = ygg.address,
            .dest = NetworkPacket.BROADCAST_ADDR,
            .broadcast = true,
            .len = 1,
        };
        packet.payload[0] = @backingInt(AppPacket.Opcode.hello);

        try ygg.writePacket(&packet);
    }

    fn resetLink(neighbor: *routing.MessageQueueMap) void {
        neighbor.sn = false;
        neighbor.nesn = false;
        neighbor.ack_pending = false;
    }

    fn isHello(packet: *const NetworkPacket) bool {
        const app = AppPacket.parse(packet.body()) orelse return false;
        return app.op == .hello;
    }

    fn replyHello(ygg: *Yggdrasil, addr: u16) (NeighborError || SendError)!void {
        const known = ygg.forwarding_table.neighborByAddr(addr) != null;
        const neighbor = try ygg.learnNeighbor(addr);

        if (known)
            resetLink(neighbor);

        var reply = NetworkPacket{
            .from = ygg.address,
            .to = addr,
            .origin = ygg.address,
            .dest = addr,
            .ack = true,
            .len = 1,
        };
        reply.payload[0] = @backingInt(AppPacket.Opcode.hello);

        try ygg.outgoing_packets.pushMessage(neighbor.mq_idx, reply, MessageQueue.PRIORITY_HIGH);
    }

    fn forward(ygg: *Yggdrasil, packet: NetworkPacket) void {
        const hop = ygg.forwarding_table.nextHop(packet.dest) orelse return;

        if (hop.addr == packet.from)
            return;

        var forwarded = packet;
        forwarded.from = ygg.address;
        forwarded.to = hop.addr;
        forwarded.crc = null;

        ygg.outgoing_packets.pushMessage(hop.mq_idx, forwarded, MessageQueue.PRIORITY_LOW) catch {};
    }

    fn handleBroadcast(ygg: *Yggdrasil, packet: NetworkPacket) void {
        if (packet.from == ygg.address)
            return;

        if (isHello(&packet))
            ygg.replyHello(packet.from) catch {};

        ygg.result_cb(packet);
    }

    /// Handles network level packets that are relevant to routing tables, forwarding,
    /// etc. Passes through most (maybe all?) messages to the app level callback as well
    pub fn handle_network_packet(ygg: *Yggdrasil, packet: NetworkPacket) void {
        if (packet.broadcast) {
            ygg.handleBroadcast(packet);
            return;
        }

        if (packet.to != ygg.address)
            return;

        if (packet.ack and isHello(&packet))
            _ = ygg.learnNeighbor(packet.from) catch {};

        if (ygg.forwarding_table.neighborByAddr(packet.from)) |neighbor| {
            if (link_layer.isLinkOnly(&packet)) {
                link_layer.processAck(ygg, neighbor, packet.nesn);
                return;
            }

            if (!link_layer.linkLayerProcess(ygg, neighbor, packet.sn, packet.nesn))
                return;
        }

        if (packet.dest == ygg.address) {
            ygg.result_cb(packet);
        } else {
            ygg.forward(packet);
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
                    ygg.packet_buffer[0 .. ygg.building_packet.len + NetworkPacket.HEADER_LEN],
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
                } else {
                    ygg.cursor = 0;
                }
            },

            .awaiting_from_msb => {
                ygg.building_packet.from = @as(u16, byte) << 8;
                ygg.state = .awaiting_from_lsb;
            },
            .awaiting_from_lsb => {
                ygg.building_packet.from |= byte;
                ygg.state = .awaiting_to_msb;
            },

            .awaiting_to_msb => {
                ygg.building_packet.to = @as(u16, byte) << 8;
                ygg.state = .awaiting_to_lsb;
            },
            .awaiting_to_lsb => {
                ygg.building_packet.to |= byte;
                ygg.state = .awaiting_origin_msb;
            },

            .awaiting_origin_msb => {
                ygg.building_packet.origin = @as(u16, byte) << 8;
                ygg.state = .awaiting_origin_lsb;
            },
            .awaiting_origin_lsb => {
                ygg.building_packet.origin |= byte;
                ygg.state = .awaiting_dest_msb;
            },

            .awaiting_dest_msb => {
                ygg.building_packet.dest = @as(u16, byte) << 8;
                ygg.state = .awaiting_dest_lsb;
            },
            .awaiting_dest_lsb => {
                ygg.building_packet.dest |= byte;
                ygg.state = .awaiting_flags;
            },

            .awaiting_flags => {
                ygg.building_packet.parseFlags(byte);
                ygg.state = .awaiting_len;
            },

            .awaiting_len => {
                ygg.building_packet.len = byte;

                if (byte > NetworkPacket.MAX_PAYLOAD_SIZE) {
                    ygg.state = .awaiting_header;
                    ygg.cursor = 0;
                } else if (byte == 0) {
                    ygg.state = .awaiting_crc_msb;
                } else {
                    ygg.state = .reading_payload;
                }
            },
            .reading_payload => {
                ygg.building_packet.payload[ygg.cursor - NetworkPacket.HEADER_LEN - 1] = byte;
                if (ygg.cursor == ygg.building_packet.len + NetworkPacket.HEADER_LEN) {
                    ygg.state = .awaiting_crc_msb;
                }
            },

            .awaiting_crc_msb => {
                ygg.building_packet.crc = @as(u16, byte) << 8;
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

const TestNet = struct {
    var wire: [TX_BUFFER_SIZE]u8 = undefined;
    var wire_len: usize = 0;
    var delivered: ?NetworkPacket = null;

    fn read(buf: []u8) YggdrasilError![]u8 {
        return buf[0..0];
    }

    fn write(buf: []u8) YggdrasilError!void {
        @memcpy(wire[0..buf.len], buf);
        wire_len = buf.len;
    }

    fn cb(packet: NetworkPacket) void {
        delivered = packet;
    }

    fn node(addr: u16) Yggdrasil {
        return .{
            .read_bytes_fn = read,
            .write_bytes_fn = write,
            .result_cb = cb,
            .address = addr,
        };
    }

    fn hear(ygg: *Yggdrasil) !void {
        for (wire[0..wire_len]) |byte| {
            if (ygg.readByte(byte)) |packet| {
                try std.testing.expect(NetworkPacket.CRC.validateCRC(
                    ygg.packet_buffer[0 .. packet.len + NetworkPacket.HEADER_LEN],
                    packet.crc.?,
                ));
                ygg.handle_network_packet(packet);
            }
        }
    }

    fn transmit(from: *Yggdrasil, listeners: []const *Yggdrasil) !void {
        try std.testing.expect(try from.requestWrite());
        for (listeners) |listener| try hear(listener);
    }
};

test "hello handshake registers neighbors on both sides" {
    var a = TestNet.node(1);
    var b = TestNet.node(2);

    try a.sayHello();
    try TestNet.hear(&b);

    try std.testing.expect(TestNet.delivered.?.broadcast);
    try std.testing.expect(b.forwarding_table.neighborByAddr(1) != null);
    try std.testing.expect(a.forwarding_table.neighborByAddr(2) == null);

    try TestNet.transmit(&b, &.{&a});

    try std.testing.expect(a.forwarding_table.neighborByAddr(2) != null);
    try std.testing.expect(TestNet.delivered.?.ack);
    try std.testing.expectEqual(AppPacket.Opcode.hello, AppPacket.parse(TestNet.delivered.?.body()).?.op);

    try TestNet.transmit(&a, &.{&b});

    try std.testing.expect(b.outgoing_packets.allEmpty());
    try std.testing.expect(a.outgoing_packets.allEmpty());
    try std.testing.expect(!try a.requestWrite());
    try std.testing.expect(!try b.requestWrite());
}

test "packets are forwarded across hops with origin preserved" {
    var a = TestNet.node(1);
    var b = TestNet.node(2);
    var c = TestNet.node(3);

    try a.sayHello();
    try TestNet.hear(&b);
    try TestNet.transmit(&b, &.{ &a, &c });
    try TestNet.transmit(&a, &.{&b});

    try c.sayHello();
    try TestNet.hear(&b);
    try TestNet.transmit(&b, &.{ &a, &c });
    try TestNet.transmit(&c, &.{&b});

    try std.testing.expect(c.forwarding_table.neighborByAddr(1) == null);

    try a.forwarding_table.setRoute(3, a.forwarding_table.neighborByAddr(2).?.mq_idx);
    try c.forwarding_table.setRoute(1, c.forwarding_table.neighborByAddr(2).?.mq_idx);

    TestNet.delivered = null;

    try a.send(3, "hi", MessageQueue.PRIORITY_LOW);
    try TestNet.transmit(&a, &.{ &b, &c });
    try std.testing.expect(TestNet.delivered == null);

    try TestNet.transmit(&b, &.{&a});
    try std.testing.expect(a.outgoing_packets.allEmpty());

    try TestNet.transmit(&b, &.{ &a, &c });

    const got = TestNet.delivered.?;
    try std.testing.expectEqual(@as(u16, 1), got.origin);
    try std.testing.expectEqual(@as(u16, 3), got.dest);
    try std.testing.expectEqual(@as(u16, 2), got.from);
    try std.testing.expectEqualSlices(u8, "hi", got.body());

    try TestNet.transmit(&c, &.{&b});
    try std.testing.expect(b.outgoing_packets.allEmpty());

    try std.testing.expectError(error.NoRoute, b.send(99, "x", MessageQueue.PRIORITY_LOW));
}

test {
    _ = @import("network_packet.zig");
    _ = @import("app_packet.zig");
    _ = @import("routing.zig");
    _ = @import("message_queue.zig");
    _ = @import("link_layer.zig");
}
