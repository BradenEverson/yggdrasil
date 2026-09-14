//! Root protocol implementation

const std = @import("std");

pub const Packet = @import("packet.zig");
pub const Opcode = Packet.Opcode;

/// Errors that are common to most APIs and
/// communication methods
pub const YggdrasilError = error{};
const LARGEST_PACKET_SIZE: usize = 1 + 1 + 2 + Packet.largestPayload() + 2;

/// The states we can be in while reading
/// from the incoming stream
pub const ParseState = enum {
    awaiting_header,

    awaiting_opcode,

    awaiting_len_msb,
    awaiting_len_lsb,

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

    state: ParseState = .awaiting_header,
    cursor: usize = 0,

    buffer: []u8 = undefined,
    packet_buffer: [LARGEST_PACKET_SIZE]u8 = undefined,

    result_cb: *const fn (packet: Packet) void,

    building_packet: Packet = .{},

    pub fn readStream(ygg: *Yggdrasil) YggdrasilError!void {
        const bytes = try ygg.read_bytes_fn(ygg.buffer);

        for (bytes) |byte| {
            if (ygg.readByte(byte)) |packet| {
                if (Packet.CRC.validateCRC(
                    ygg.packet_buffer[0 .. ygg.building_packet.payload.len + 4],
                    ygg.building_packet.crc.?,
                )) {
                    ygg.result_cb(packet);
                } else {
                    // Error callback here?
                    // Send a NACK at least

                    ygg.packet_buffer[0] = 0x00; // malformed packet nack
                    const nack = Packet{
                        .op = .nack,
                        .len = 1,
                        .payload = ygg.packet_buffer[0..1],
                        .crc = null,
                    };

                    const nack_packet = nack.toBuffer(&ygg.packet_buffer);
                    try ygg.write_bytes_fn(nack_packet);
                }
            }
        }
    }

    pub fn readByte(ygg: *Yggdrasil, byte: u8) ?Packet {
        switch (ygg.state) {
            .awaiting_header => {
                if (byte == Packet.HEADER) {
                    ygg.state = .awaiting_opcode;
                    ygg.packet_buffer[0] = byte;
                }
            },
            .awaiting_opcode => {
                if (byte < @intFromEnum(Opcode.OPCODE_MAX)) {
                    ygg.building_packet.op = @enumFromInt(byte);
                    ygg.state = .awaiting_len_msb;
                    ygg.packet_buffer[1] = byte;
                } else {
                    ygg.state = .awaiting_header;
                }
            },
            .awaiting_len_msb => {
                ygg.building_packet.len = 0;
                ygg.building_packet.len |= byte;
                ygg.building_packet.len <<= 8;
                ygg.state = .awaiting_len_lsb;
                ygg.packet_buffer[2] = byte;
            },
            .awaiting_len_lsb => {
                ygg.building_packet.len |= byte;
                ygg.packet_buffer[3] = byte;

                if (ygg.building_packet.len == 0) {
                    ygg.building_packet.payload = ygg.packet_buffer[4..4];
                    ygg.state = .awaiting_crc_msb;
                } else {
                    ygg.state = .reading_payload;
                    ygg.cursor = 0;
                }
            },
            .reading_payload => {
                ygg.packet_buffer[4 + ygg.cursor] = byte;
                ygg.cursor += 1;

                if (ygg.cursor == ygg.building_packet.len) {
                    ygg.building_packet.payload = ygg.packet_buffer[4 .. 4 + ygg.building_packet.len];
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
                return ygg.building_packet;
            },
        }

        return null;
    }
};

test {
    _ = @import("packet.zig");
    _ = @import("message.zig");
}

fn nopRead(buf: []u8) YggdrasilError![]u8 {
    const nop = [6]u8{ 0x72, 0x00, 0x00, 0x00, 0x40, 0x90 };
    buf[0] = nop[0];
    buf[1] = nop[1];
    buf[2] = nop[2];
    buf[3] = nop[3];
    buf[4] = nop[4];
    buf[5] = nop[5];

    return buf[0..6];
}

fn ackWithPayloadRead(buf: []u8) YggdrasilError![]u8 {
    const ack = [10]u8{ 0x72, 0x01, 0x00, 0x04, 0xDE, 0xAD, 0xBE, 0xEF, 0x4D, 0xA8 };
    buf[0] = ack[0];
    buf[1] = ack[1];
    buf[2] = ack[2];
    buf[3] = ack[3];
    buf[4] = ack[4];
    buf[5] = ack[5];
    buf[6] = ack[6];
    buf[7] = ack[7];
    buf[8] = ack[8];
    buf[9] = ack[9];

    return buf[0..10];
}

fn emptyWrite(buf: []u8) YggdrasilError!void {
    _ = buf;
}

fn yay(packet: Packet) void {
    std.debug.print("{any}\n", .{packet});
}

test {
    _ = @import("packet.zig");
    _ = @import("message.zig");
}

test "Simple packet parsing" {
    var buffer: [64]u8 = undefined;

    var ygg = Yggdrasil{
        .read_bytes_fn = nopRead,
        .write_bytes_fn = emptyWrite,
        .result_cb = yay,
        .buffer = &buffer,
    };

    try ygg.readStream();
}

test "Payload packet parsing" {
    var buffer: [64]u8 = undefined;

    var ygg = Yggdrasil{
        .read_bytes_fn = ackWithPayloadRead,
        .write_bytes_fn = emptyWrite,
        .result_cb = yay,
        .buffer = &buffer,
    };

    try ygg.readStream();
}
