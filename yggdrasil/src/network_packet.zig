//! Raw Packet structure

const std = @import("std");
pub const CRC = @import("network_packet/crc.zig");

pub const HEADER: u8 = 0x72;

from: u16 = 0,
to: u16 = 0,
sn: u16 = 0,
ack: bool = false,
broadcast: bool = false,
len: u16 = 0,
payload: []const u8 = undefined,
crc: ?u16 = null,

const Packet = @This();

pub fn toBuffer(self: *const Packet, buf: []u8) []u8 {
    // TODO!
    buf[0] = HEADER;
    buf[1] = @intFromEnum(self.op);

    const len_msb: u8 = @truncate(self.len >> 8);
    const len_lsb: u8 = @truncate(self.len >> 0);

    buf[2] = len_msb;
    buf[3] = len_lsb;

    for (self.payload, 0..) |byte, i| {
        buf[4 + i] = byte;
    }

    const crc = if (self.crc) |crc|
        crc
    else
        CRC.getCRC(buf[0..self.payload.len]);

    const crc_msb: u8 = @truncate(crc >> 8);
    const crc_lsb: u8 = @truncate(crc >> 0);

    buf[4 + self.payload.len + 0] = crc_msb;
    buf[4 + self.payload.len + 1] = crc_lsb;

    return buf[0 .. 4 + self.payload.len + 2];
}

test {
    _ = @import("network_packet/crc.zig");
}
