//! Raw Packet structure

const std = @import("std");
pub const CRC = @import("network_packet/crc.zig");

pub const HEADER: u8 = 0x72;
pub const BROADCAST_ADDR: u16 = 0xFFFF;
pub const HEADER_LEN: usize = 12;

const ACK_BIT: u8 = 7;
const BROADCAST_BIT: u8 = 6;
const NACK_BIT: u8 = 5;
const SN_BIT: u8 = 4;
const NESN_BIT: u8 = 3;

/// LoRA max - header - from - to - origin - dest - ttl - flags - len - crc
pub const MAX_PAYLOAD_SIZE: usize = 240 - 1 - 2 - 2 - 2 - 2 - 1 - 1 - 1 - 2;

from: u16 = 0,
to: u16 = 0,
origin: u16 = 0,
dest: u16 = 0,
ttl: u8 = 1,
ack: bool = false,
broadcast: bool = false,
nack: bool = false,
sn: bool = false,
nesn: bool = false,
len: u8 = 0,
payload: [MAX_PAYLOAD_SIZE]u8 = undefined,
crc: ?u16 = null,

const Packet = @This();

pub fn parseFlags(self: *Packet, flags: u8) void {
    self.ack = (flags >> ACK_BIT) & 0x1 == 0x1;
    self.broadcast = (flags >> BROADCAST_BIT) & 0x1 == 0x1;
    self.nack = (flags >> NACK_BIT) & 0x1 == 0x1;
    self.sn = (flags >> SN_BIT) & 0x1 == 0x1;
    self.nesn = (flags >> NESN_BIT) & 0x1 == 0x1;
}

fn flagByte(self: *const Packet) u8 {
    var flag: u8 = 0;

    if (self.ack)
        flag |= 1 << ACK_BIT;
    if (self.broadcast)
        flag |= 1 << BROADCAST_BIT;
    if (self.nack)
        flag |= 1 << NACK_BIT;
    if (self.sn)
        flag |= 1 << SN_BIT;
    if (self.nesn)
        flag |= 1 << NESN_BIT;

    return flag;
}

pub fn toBuffer(self: *Packet, buf: []u8) []u8 {
    buf[0] = HEADER;

    buf[1] = @truncate(self.from >> 8);
    buf[2] = @truncate(self.from >> 0);

    buf[3] = @truncate(self.to >> 8);
    buf[4] = @truncate(self.to >> 0);

    buf[5] = @truncate(self.origin >> 8);
    buf[6] = @truncate(self.origin >> 0);

    buf[7] = @truncate(self.dest >> 8);
    buf[8] = @truncate(self.dest >> 0);

    buf[9] = self.ttl;

    buf[10] = self.flagByte();

    buf[11] = self.len;

    @memcpy(buf[HEADER_LEN .. HEADER_LEN + self.len], self.payload[0..self.len]);

    if (self.crc == null)
        self.crc = CRC.getCRC(buf[0 .. HEADER_LEN + self.len]);

    buf[HEADER_LEN + self.len + 0] = @truncate(self.crc.? >> 8);
    buf[HEADER_LEN + self.len + 1] = @truncate(self.crc.? >> 0);

    return buf[0 .. HEADER_LEN + self.len + 2];
}

pub fn setPayload(self: *Packet, bytes: []const u8) error{PayloadTooLarge}!void {
    if (bytes.len > MAX_PAYLOAD_SIZE)
        return error.PayloadTooLarge;

    self.len = @intCast(bytes.len);
    @memcpy(self.payload[0..bytes.len], bytes);
}

pub fn body(self: *const Packet) []const u8 {
    return self.payload[0..self.len];
}

test "to buffer" {
    var buf: [64]u8 = undefined;

    var p = Packet{
        .from = 0xDEAD,
        .to = 0xBEEF,
        .origin = 0x1234,
        .dest = 0x5678,
        .ttl = 3,

        .ack = false,
        .broadcast = true,
        .nack = false,
        .sn = false,
        .nesn = true,

        .len = 2,
    };
    p.payload[0] = 0xBE;
    p.payload[1] = 0xAD;

    const packet_buf = p.toBuffer(&buf);

    const expected = [_]u8{
        0x72,

        0xDE,
        0xAD,

        0xBE,
        0xEF,

        0x12,
        0x34,

        0x56,
        0x78,

        0x03,

        0x48,

        0x02,

        0xBE,
        0xAD,

        // We keep crc as null, so this enforces that
        // writing to buffer with a null crc first
        // calculates the crc
        0xE3,
        0x28,
    };

    try std.testing.expectEqualSlices(u8, &expected, packet_buf);
}

test {
    _ = @import("network_packet/crc.zig");
}
