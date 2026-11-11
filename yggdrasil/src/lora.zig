const std = @import("std");

pub const Radio = struct {
    spreading_factor: u4 = 9,
    bandwidth_hz: u32 = 125_000,
    coding_rate: u3 = 1,
    preamble: u8 = 4,
    overhead_bytes: u8 = 8,
    uart_baud: u32 = 115_200,
    uart_overhead_bytes: u8 = 40,

    pub fn symbolUs(r: Radio) u64 {
        return (@as(u64, 1) << r.spreading_factor) * 1_000_000 / r.bandwidth_hz;
    }

    pub fn airtimeUs(r: Radio, payload_len: usize) u64 {
        const sf: i64 = r.spreading_factor;
        const de: i64 = if (r.symbolUs() >= 16_000) 1 else 0;
        const pl: i64 = @intCast(payload_len + r.overhead_bytes);

        const n = 8 * pl - 4 * sf + 28 + 16;
        const d = 4 * (sf - 2 * de);
        const blocks: i64 = if (n > 0) @divFloor(n + d - 1, d) else 0;
        const payload_symbols: u64 = @intCast(8 + blocks * (@as(i64, r.coding_rate) + 4));

        const quarter_symbols = 4 * (@as(u64, r.preamble) + 4) + 1 + 4 * payload_symbols;
        return quarter_symbols * (@as(u64, 1) << r.spreading_factor) * 1_000_000 / (4 * @as(u64, r.bandwidth_hz));
    }

    pub fn uartUs(r: Radio, payload_len: usize) u64 {
        const chars: u64 = 2 * @as(u64, payload_len) + r.uart_overhead_bytes;
        return chars * 10 * 1_000_000 / r.uart_baud;
    }

    pub fn frameMs(r: Radio, payload_len: usize) u32 {
        const us = r.airtimeUs(payload_len) + r.uartUs(payload_len);
        return @intCast((us + 999) / 1000);
    }
};

test "airtime matches the semtech calculator" {
    const sf7: Radio = .{ .spreading_factor = 7, .preamble = 8, .overhead_bytes = 0 };
    try std.testing.expectEqual(@as(u64, 41_216), sf7.airtimeUs(10));

    const sf12: Radio = .{ .spreading_factor = 12, .preamble = 8, .overhead_bytes = 0 };
    try std.testing.expectEqual(@as(u64, 991_232), sf12.airtimeUs(10));
}

test "lower spreading factors are faster" {
    const slow: Radio = .{ .spreading_factor = 12 };
    const fast: Radio = .{ .spreading_factor = 9 };
    try std.testing.expect(fast.frameMs(45) * 5 < slow.frameMs(45));
}
