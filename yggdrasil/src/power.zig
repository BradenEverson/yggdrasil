const std = @import("std");
const NetworkPacket = @import("network_packet.zig");
pub const Radio = @import("lora.zig").Radio;

pub const ACK_FRAME: usize = NetworkPacket.HEADER_LEN + 2;
pub const MAX_WAKE_IN: u32 = std.math.maxInt(u24);
pub const PERIOD_UNIT_MS: u32 = 100;

pub const Power = struct {
    period_ms: u32 = 0,
    window_ms: u32 = 0,
    frame_budget: usize = 64,
    guard_ms: u32 = 20,
    drift_ppm: u32 = 40,
    radio_wake_ms: u32 = 100,
    slack_ms: u32 = 50,
    max_hops: u8 = 32,
    reverse_route_hops: u8 = 8,
    join_backoff_max_ms: u32 = 30 * 60_000,
    join_backoff_fresh_max_ms: u32 = 5 * 60_000,
    join_hellos: u8 = 3,
    root_beacon_ms: u32 = 0,
    report_holddown_ms: u32 = 10_000,
    report_refresh_ms: u32 = 60 * 60_000,
    neighbor_timeout_ms: u32 = 0,
    root_holddown_ms: u32 = 0,
    legacy_periods: u8 = 3,
    max_idle_ms: u32 = 60 * 60_000,
    radio: Radio = .{},

    pub fn sleepy(p: Power) bool {
        return p.periodMs() != 0;
    }

    pub fn periodMs(p: Power) u32 {
        return @as(u32, p.advertisedPeriod()) * PERIOD_UNIT_MS;
    }

    pub fn frameMs(p: Power, len: usize) u32 {
        return p.radio.frameMs(len);
    }

    pub fn backoffMs(p: Power) u32 {
        return 2 * p.frameMs(ACK_FRAME);
    }

    pub fn windowMs(p: Power) u32 {
        if (p.window_ms != 0) return p.window_ms;
        return 2 * p.guard_ms + p.backoffMs() + p.frameMs(p.frame_budget) + p.frameMs(ACK_FRAME) + p.slack_ms;
    }

    pub fn lingerMs(p: Power, sent_len: usize) u32 {
        return p.frameMs(sent_len) + p.frameMs(p.frame_budget) + 2 * p.guard_ms + p.slack_ms;
    }

    pub fn guardMs(p: Power, elapsed_ms: u32) u32 {
        const drift: u64 = @as(u64, elapsed_ms) * p.drift_ppm / 1_000_000;
        return p.guard_ms +| @as(u32, @intCast(@min(drift, std.math.maxInt(u32))));
    }

    pub fn scanMs(p: Power) u32 {
        if (!p.sleepy()) return 4 * p.windowMs();
        return p.periodMs() + p.windowMs() + p.lingerMs(p.frame_budget);
    }

    pub fn helloSpacingMs(p: Power) u32 {
        return p.scanMs() / @max(p.join_hellos, 1);
    }

    pub fn rootHolddownMs(p: Power) u32 {
        if (p.root_holddown_ms != 0) return p.root_holddown_ms;
        return 4 * @max(p.periodMs(), p.windowMs());
    }

    pub fn advertisedPeriod(p: Power) u16 {
        return @intCast(@min(p.period_ms / PERIOD_UNIT_MS, std.math.maxInt(u16)));
    }
};

pub fn after(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) > 0;
}

pub fn reached(at: u32, deadline: u32) bool {
    return @as(i32, @bitCast(at -% deadline)) >= 0;
}

pub fn windowAt(anchor: u32, period: u32, now: u32) u32 {
    const d: i32 = @bitCast(now -% anchor);
    if (d >= 0) return anchor +% (@as(u32, @intCast(d)) / period) * period;
    const back = (@as(u32, @intCast(-@as(i64, d))) + period - 1) / period;
    return anchor -% back * period;
}

test "window anchors step forwards and backwards across wraparound" {
    try std.testing.expectEqual(@as(u32, 1000), windowAt(1000, 500, 1000));
    try std.testing.expectEqual(@as(u32, 1000), windowAt(1000, 500, 1499));
    try std.testing.expectEqual(@as(u32, 1500), windowAt(1000, 500, 1500));
    try std.testing.expectEqual(@as(u32, 500), windowAt(1000, 500, 999));
    try std.testing.expectEqual(@as(u32, 0), windowAt(1000, 500, 0));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FE64), windowAt(100, 512, 0xFFFF_FF10));
}

test "derived timings grow with spreading factor" {
    const fast: Power = .{ .period_ms = 60_000, .radio = .{ .spreading_factor = 7 } };
    const slow: Power = .{ .period_ms = 60_000, .radio = .{ .spreading_factor = 12 } };
    try std.testing.expect(fast.windowMs() < slow.windowMs());
    try std.testing.expect(fast.windowMs() < 1000);
    try std.testing.expectEqual(@as(u32, 20), fast.guardMs(0));
    try std.testing.expectEqual(@as(u32, 22), fast.guardMs(60_000));
    try std.testing.expectEqual(@as(u16, 600), fast.advertisedPeriod());
}
