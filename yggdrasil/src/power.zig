const std = @import("std");
const NetworkPacket = @import("network_packet.zig");
pub const Radio = @import("lora.zig").Radio;

pub const ACK_FRAME: usize = NetworkPacket.BASE_HEADER_LEN + 2;
pub const PERIOD_UNIT_MS: u32 = 100;
pub const GUARD_FIXED_MS: u32 = 10;
pub const GUARD_SYMBOLS: u32 = 2;
pub const SLACK_FIXED_MS: u32 = 25;
pub const SLACK_SYMBOLS: u32 = 6;

pub const Power = struct {
    period_ms: u32 = 0,
    window_ms: u32 = 0,
    frame_budget: usize = 32,
    guard_ms: u32 = 0,
    drift_ppm: u32 = 40,
    radio_wake_ms: u32 = 100,
    slack_ms: u32 = 0,
    max_hops: u8 = 32,
    reverse_route_hops: u8 = 8,
    join_backoff_max_ms: u32 = 30 * 60_000,
    join_backoff_fresh_max_ms: u32 = 5 * 60_000,
    join_hellos: u8 = 3,
    root_beacon_ms: u32 = 0,
    beacon_periods: u8 = 1,
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
        return 2 * p.baseGuardMs() + p.backoffMs() + p.frameMs(p.frame_budget) + p.frameMs(ACK_FRAME) + p.slackMs();
    }

    pub fn baseGuardMs(p: Power) u32 {
        if (p.guard_ms != 0) return p.guard_ms;
        return GUARD_FIXED_MS + p.radio.symbolsMs(GUARD_SYMBOLS);
    }

    pub fn slackMs(p: Power) u32 {
        if (p.slack_ms != 0) return p.slack_ms;
        return SLACK_FIXED_MS + p.radio.symbolsMs(SLACK_SYMBOLS);
    }

    pub fn lingerMs(p: Power, sent_len: usize) u32 {
        return p.frameMs(sent_len) + p.frameMs(p.frame_budget) + 2 * p.baseGuardMs() + p.slackMs();
    }

    pub fn guardMs(p: Power, elapsed_ms: u32) u32 {
        const drift: u64 = @as(u64, elapsed_ms) * p.drift_ppm / 1_000_000;
        return p.baseGuardMs() +| @as(u32, @intCast(@min(drift, std.math.maxInt(u32))));
    }

    pub fn scanMs(p: Power) u32 {
        if (!p.sleepy()) return 4 * p.windowMs();
        return @as(u32, @max(p.beacon_periods, 1)) * p.periodMs() + p.windowMs() + p.lingerMs(p.frame_budget);
    }

    pub fn beaconIntervalMs(p: Power) u32 {
        return @as(u32, p.beacon_periods) * p.periodMs();
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
    try std.testing.expectEqual(@as(u32, 13), fast.guardMs(0));
    try std.testing.expectEqual(@as(u32, 15), fast.guardMs(60_000));
    try std.testing.expectEqual(@as(u32, 32), fast.slackMs());
    try std.testing.expectEqual(@as(u16, 600), fast.advertisedPeriod());
}

test "derived guard and slack keep the sf9 margins and scale with symbol time" {
    const sf9: Power = .{ .radio = .{ .spreading_factor = 9 } };
    try std.testing.expectEqual(@as(u32, 19), sf9.baseGuardMs());
    try std.testing.expectEqual(@as(u32, 50), sf9.slackMs());

    const sf12: Power = .{ .radio = .{ .spreading_factor = 12 } };
    try std.testing.expectEqual(@as(u32, 76), sf12.baseGuardMs());
    try std.testing.expectEqual(@as(u32, 222), sf12.slackMs());

    const pinned: Power = .{ .guard_ms = 20, .slack_ms = 50 };
    try std.testing.expectEqual(@as(u32, 20), pinned.baseGuardMs());
    try std.testing.expectEqual(@as(u32, 50), pinned.slackMs());
}
