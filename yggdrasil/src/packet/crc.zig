//! Cyclic Redundancy Check (CRC) from scratch ooo la la

const std = @import("std");

const GENERATOR: u16 = 0b1011011101001000;

pub fn getCRC(data: []const u8) u16 {
    var crc: u16 = 0;

    for (data) |byte| {
        crc ^= @as(u16, byte) << 8;

        for (0..8) |_| {
            if (crc & 0x8000 != 0) {
                crc = (crc << 1) ^ GENERATOR;
            } else {
                crc <<= 1;
            }
        }
    }

    return crc;
}

pub fn validateCRC(data: []const u8, crc: u16) bool {
    return getCRC(data) == crc;
}

test "validate sequences" {
    const seq1 = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    try std.testing.expectEqual(0x95E0, getCRC(&seq1));

    const seq2 = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    try std.testing.expectEqual(0x5458, getCRC(&seq2));
}

test "wrong crc" {
    var data = "123456789".*;
    const crc = getCRC(&data);
    try std.testing.expect(!validateCRC(&data, crc ^ 0x0001));
}

test "get crcs I need" {
    const nop = [4]u8{ 0x72, 0x00, 0x00, 0x00 };
    try std.testing.expectEqual(0x4090, getCRC(&nop));

    const ack = [8]u8{ 0x72, 0x01, 0x00, 0x04, 0xDE, 0xAD, 0xBE, 0xEF };
    try std.testing.expectEqual(0x4DA8, getCRC(&ack));
}
