//! Raw Packet structure

const std = @import("std");
pub const CRC = @import("packet/crc.zig");

pub const Opcode = enum(u8) {
    nop,
    ack,
    nack,
    OPCODE_MAX,
};

pub fn payloadSize(comptime op: Opcode) comptime_int {
    return switch (op) {
        .nop => 0,
        .ack => 4,
        .nack => 1,
        .OPCODE_MAX => unreachable,
    };
}

pub fn largestPayload() comptime_int {
    var max: comptime_int = 0;

    comptime for (0..@intFromEnum(Opcode.OPCODE_MAX)) |i| {
        const size = payloadSize(@enumFromInt(i));
        if (size > max) {
            max = size;
        }
    };

    return max;
}

pub const HEADER: u8 = 0x72;

op: Opcode = .nop,
len: u16 = 0,
payload: []u8 = undefined,
crc: u16 = 0,

const Packet = @This();

pub fn toBuffer(self: *const Packet, buf: []u8) []u8 {
    buf[0] = HEADER;
    buf[1] = @intFromEnum(self.op);

    const len_msb: u8 = @truncate(self.len >> 8);
    const len_lsb: u8 = @truncate(self.len >> 0);

    buf[2] = len_msb;
    buf[3] = len_lsb;

    for (self.payload, 0..) |byte, i| {
        buf[4 + i] = byte;
    }

    const crc_msb: u8 = @truncate(self.crc >> 8);
    const crc_lsb: u8 = @truncate(self.crc >> 0);

    buf[4 + self.payload.len + 0] = crc_msb;
    buf[4 + self.payload.len + 1] = crc_lsb;

    return buf[0 .. 4 + self.payload.len + 2];
}

test {
    _ = @import("packet/crc.zig");
}
