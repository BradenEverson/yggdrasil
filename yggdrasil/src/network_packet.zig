//! Raw Packet structure

const std = @import("std");

pub const Address = u8;
pub const BROADCAST_ADDR: Address = 0xFF;
pub const NO_HOPS: u8 = 0xFF;

pub const MAX_FRAME_LEN: usize = 240;
pub const BASE_HEADER_LEN: usize = 4;
pub const MAX_HEADER_LEN: usize = BASE_HEADER_LEN + 1 + 2 + 2 + 2;
pub const MAX_PAYLOAD_SIZE: usize = MAX_FRAME_LEN - MAX_HEADER_LEN;

const ACK_BIT: u3 = 7;
const BROADCAST_BIT: u3 = 6;
const SN_BIT: u3 = 5;
const NESN_BIT: u3 = 4;
const ORIGIN_BIT: u3 = 3;
const DEST_BIT: u3 = 2;
const WAKE_BIT: u3 = 1;
const PERIOD_BIT: u3 = 0;

from: Address = 0,
to: Address = 0,
origin: Address = 0,
dest: Address = 0,
ttl: u8 = 1,
ack: bool = false,
broadcast: bool = false,
sn: bool = false,
nesn: bool = false,
len: u8 = 0,
wake_phase: ?u16 = null,
period: ?u16 = null,
hops: u8 = NO_HOPS,
payload: [MAX_PAYLOAD_SIZE]u8 = undefined,

const Packet = @This();

fn hasOrigin(self: *const Packet) bool {
    return self.origin != self.from;
}

fn hasDest(self: *const Packet) bool {
    return self.dest != self.to or (self.to == BROADCAST_ADDR and self.ttl != 1);
}

fn bit(comptime b: u3, on: bool) u8 {
    return if (on) @as(u8, 1) << b else 0;
}

fn isSet(flags: u8, comptime b: u3) bool {
    return flags & (@as(u8, 1) << b) != 0;
}

pub fn headerLen(self: *const Packet) usize {
    var n = BASE_HEADER_LEN;
    if (self.hasOrigin()) n += 1;
    if (self.hasDest()) n += 2;
    if (self.wake_phase != null) n += 2;
    if (self.period != null) n += 2;
    return n;
}

pub fn frameLen(self: *const Packet) usize {
    return self.headerLen() + self.len;
}

pub fn toBuffer(self: *const Packet, buf: []u8) []u8 {
    buf[0] = bit(ACK_BIT, self.ack) |
        bit(BROADCAST_BIT, self.broadcast) |
        bit(SN_BIT, self.sn) |
        bit(NESN_BIT, self.nesn) |
        bit(ORIGIN_BIT, self.hasOrigin()) |
        bit(DEST_BIT, self.hasDest()) |
        bit(WAKE_BIT, self.wake_phase != null) |
        bit(PERIOD_BIT, self.period != null);
    buf[1] = self.from;
    buf[2] = self.to;
    buf[3] = self.hops;

    var n: usize = BASE_HEADER_LEN;
    if (self.hasOrigin()) {
        buf[n] = self.origin;
        n += 1;
    }
    if (self.hasDest()) {
        buf[n] = self.dest;
        buf[n + 1] = self.ttl;
        n += 2;
    }
    if (self.wake_phase) |phase| {
        std.mem.writeInt(u16, buf[n..][0..2], phase, .big);
        n += 2;
    }
    if (self.period) |period| {
        std.mem.writeInt(u16, buf[n..][0..2], period, .big);
        n += 2;
    }

    @memcpy(buf[n..][0..self.len], self.payload[0..self.len]);
    return buf[0 .. n + self.len];
}

pub fn parse(frame: []const u8) ?Packet {
    if (frame.len < BASE_HEADER_LEN or frame.len > MAX_FRAME_LEN)
        return null;

    const flags = frame[0];
    var p = Packet{
        .ack = isSet(flags, ACK_BIT),
        .broadcast = isSet(flags, BROADCAST_BIT),
        .sn = isSet(flags, SN_BIT),
        .nesn = isSet(flags, NESN_BIT),
        .from = frame[1],
        .to = frame[2],
        .hops = frame[3],
    };

    var n: usize = BASE_HEADER_LEN;
    const want = n + @as(usize, if (isSet(flags, ORIGIN_BIT)) 1 else 0) +
        @as(usize, if (isSet(flags, DEST_BIT)) 2 else 0) +
        @as(usize, if (isSet(flags, WAKE_BIT)) 2 else 0) +
        @as(usize, if (isSet(flags, PERIOD_BIT)) 2 else 0);
    if (frame.len < want)
        return null;

    p.origin = p.from;
    if (isSet(flags, ORIGIN_BIT)) {
        p.origin = frame[n];
        n += 1;
    }
    p.dest = p.to;
    if (isSet(flags, DEST_BIT)) {
        p.dest = frame[n];
        p.ttl = frame[n + 1];
        n += 2;
    }
    if (isSet(flags, WAKE_BIT)) {
        p.wake_phase = std.mem.readInt(u16, frame[n..][0..2], .big);
        n += 2;
    }
    if (isSet(flags, PERIOD_BIT)) {
        p.period = std.mem.readInt(u16, frame[n..][0..2], .big);
        n += 2;
    }

    const body_len = frame.len - n;
    if (body_len > MAX_PAYLOAD_SIZE)
        return null;
    p.len = @intCast(body_len);
    @memcpy(p.payload[0..body_len], frame[n..]);
    return p;
}

pub fn wakePhase(wake_in_ms: u32, period_ms: u32) u16 {
    if (period_ms == 0) return 0;
    const scaled = (@as(u64, wake_in_ms) * 65536 + period_ms / 2) / period_ms;
    return @intCast(@min(scaled, std.math.maxInt(u16)));
}

pub fn wakeInMs(phase: u16, period_ms: u32) u32 {
    return @intCast((@as(u64, phase) * period_ms + 32768) / 65536);
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

fn roundTrip(p: Packet) !Packet {
    var buf: [MAX_FRAME_LEN]u8 = undefined;
    const bytes = p.toBuffer(&buf);
    try std.testing.expectEqual(p.frameLen(), bytes.len);
    return parse(bytes) orelse error.ParseFailed;
}

test "single hop frames carry only the base header" {
    var p = Packet{ .from = 7, .to = 3, .origin = 7, .dest = 3, .ttl = 4, .sn = true, .hops = 2, .len = 2 };
    p.payload[0] = 0xBE;
    p.payload[1] = 0xAD;

    var buf: [MAX_FRAME_LEN]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{ 0x20, 7, 3, 2, 0xBE, 0xAD }, p.toBuffer(&buf));

    const back = try roundTrip(p);
    try std.testing.expectEqual(@as(Address, 7), back.origin);
    try std.testing.expectEqual(@as(Address, 3), back.dest);
    try std.testing.expect(back.sn and !back.nesn and !back.ack and !back.broadcast);
    try std.testing.expectEqualSlices(u8, p.body(), back.body());
}

test "relayed frames carry origin, dest, ttl and schedule" {
    var p = Packet{
        .from = 2,
        .to = 5,
        .origin = 9,
        .dest = 1,
        .ttl = 3,
        .ack = true,
        .nesn = true,
        .wake_phase = 0x1234,
        .period = 600,
        .hops = 4,
        .len = 1,
    };
    p.payload[0] = 0x42;

    var buf: [MAX_FRAME_LEN]u8 = undefined;
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x9F, 2, 5, 4, 9, 1, 3, 0x12, 0x34, 0x02, 0x58, 0x42 },
        p.toBuffer(&buf),
    );

    const back = try roundTrip(p);
    try std.testing.expectEqual(@as(Address, 9), back.origin);
    try std.testing.expectEqual(@as(Address, 1), back.dest);
    try std.testing.expectEqual(@as(u8, 3), back.ttl);
    try std.testing.expectEqual(@as(?u16, 0x1234), back.wake_phase);
    try std.testing.expectEqual(@as(?u16, 600), back.period);
}

test "broadcasts keep ttl only when it matters" {
    const hello = Packet{ .from = 4, .to = BROADCAST_ADDR, .origin = 4, .dest = BROADCAST_ADDR, .broadcast = true };
    try std.testing.expectEqual(BASE_HEADER_LEN, hello.frameLen());

    const flood = Packet{ .from = 4, .to = BROADCAST_ADDR, .origin = 4, .dest = BROADCAST_ADDR, .broadcast = true, .ttl = 5 };
    try std.testing.expectEqual(@as(u8, 5), (try roundTrip(flood)).ttl);
}

test "an ack is four bytes plus schedule" {
    const ack = Packet{ .from = 1, .to = 2, .origin = 1, .dest = 2, .nesn = true, .wake_phase = 9 };
    try std.testing.expectEqual(@as(usize, 6), ack.frameLen());
}

test "truncated and oversized frames are rejected" {
    try std.testing.expect(parse(&.{ 0, 1, 2 }) == null);
    try std.testing.expect(parse(&.{ 0x08, 1, 2, 3 }) == null);
    try std.testing.expect(parse(&.{ 0x03, 1, 2, 3, 0, 0, 0 }) == null);
    const big: [MAX_FRAME_LEN + 1]u8 = @splat(0);
    try std.testing.expect(parse(&big) == null);
}

test "wake phase round trips within a few ms" {
    const period: u32 = 300_000;
    for ([_]u32{ 1, 1234, 150_000, 299_999, 300_000 }) |ms| {
        const back = wakeInMs(wakePhase(ms, period), period);
        try std.testing.expect(@abs(@as(i64, back) - ms) <= period / 65536 + 1);
    }
}
