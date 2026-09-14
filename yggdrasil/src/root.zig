//! Root protocol implementation

const std = @import("std");

pub const Packet = @import("packet.zig");
pub const Opcode = Packet.Opcode;

/// Errors that are common to most APIs and
/// communication methods
pub const YggdrasilError = error{};

const HEADER: u8 = 0x72;
const LARGEST_PACKET_SIZE: usize = 1 + 1 + 2 + Packet.largestPayload() + 2;

/// The states we can be in while reading
/// from the incoming stream
pub const ParseState = enum {
    awaiting_header,
    awaiting_opcode,
    awaiting_len_msb,
    awaiting_len_lsb,
    reading_payload,
    reading_crc_msb,
    reading_crc_lsb,
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
                ygg.result_cb(packet);
            }
        }
    }

    pub fn readByte(ygg: *Yggdrasil, byte: u8) ?Packet {
        switch (ygg.state) {
            .awaiting_header => {
                if (byte == HEADER) {
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
                    ygg.state = .awaiting_header;
                    return ygg.building_packet;
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
                    ygg.state = .awaiting_header;
                    return ygg.building_packet;
                }
            },

            .reading_crc_msb => {},
            .reading_crc_lsb => {},
        }

        return null;
    }
};

test {
    _ = @import("packet.zig");
    _ = @import("message.zig");
}

fn nopRead(buf: []u8) YggdrasilError![]u8 {
    const nop = [4]u8{ 0x72, 0x00, 0x00, 0x00 };
    buf[0] = nop[0];
    buf[1] = nop[1];
    buf[2] = nop[2];
    buf[3] = nop[3];

    return buf[0..4];
}

fn ackWithPayloadRead(buf: []u8) YggdrasilError![]u8 {
    const ack = [8]u8{ 0x72, 0x01, 0x00, 0x04, 0xDE, 0xAD, 0xBE, 0xEF };
    buf[0] = ack[0];
    buf[1] = ack[1];
    buf[2] = ack[2];
    buf[3] = ack[3];
    buf[4] = ack[4];
    buf[5] = ack[5];
    buf[6] = ack[6];
    buf[7] = ack[7];

    return buf[0..8];
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
