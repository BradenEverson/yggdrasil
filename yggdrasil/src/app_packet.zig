//! Application level packet

const std = @import("std");

pub const Opcode = enum(u8) {
    nop,
    sensor_readings,
};

op: Opcode = .nop,
payload: []const u8 = undefined,

pub const SensorReadingStream = struct {
    buf: []u8,
    cursor: usize = 0,

    pub fn next(stream: *SensorReadingStream) ?SensorEntry {
        // Must have at least the space for length and the
        // reading type
        if (stream.buf.len < 3)
            return null;

        const len_msb = stream.buf[0];
        const len_lsb = stream.buf[1];

        var len: u16 = 0;
        len |= len_msb << 8;
        len |= len_lsb << 0;

        const val_type: ValueType = @enumFromInt(stream.buf[2]);
        _ = val_type;

        stream.buf = stream.buf[3..];

        const name_len_msb = stream.buf[0];
        const name_len_lsb = stream.buf[1];

        var name_len: u16 = 0;
        name_len |= name_len_msb << 8;
        name_len |= name_len_lsb << 0;

        stream.buf = stream.buf[2..];

        const name = stream.buf[0..name_len];
        _ = name;

        stream.buf = stream.buf[name_len..];

        return null;
    }
};

pub const ValueType = enum(u8) {
    uint8,
    uint16,
    uint32,
    uint64,
    int8,
    int16,
    int32,
    int64,
    float32,
    float64,
};

pub const Value = union(ValueType) {
    uint8: u8,
    uint16: u16,
    uint32: u32,
    uint64: u64,
    int8: i8,
    int16: i16,
    int32: i32,
    int64: i64,
    float32: f32,
    float64: f64,

    pub fn fromBytes(ty: ValueType, buf: []const u8) Value {
        switch (ty) {
            .uint8 => return .{ .uint8 = buf[0] },
            .uint16 => {
                var uint16: u16 = 0;

                uint16 |= buf[0];
                uint16 <<= 8;
                uint16 |= buf[1];

                return .{ .uint16 = uint16 };
            },
            .uint32 => {
                var uint32: u32 = 0;

                uint32 |= buf[0];
                uint32 <<= 8;
                uint32 |= buf[1];
                uint32 <<= 8;
                uint32 |= buf[2];
                uint32 <<= 8;
                uint32 |= buf[3];

                return .{ .uint32 = uint32 };
            },
            .uint64 => {
                var uint64: u64 = 0;

                uint64 |= buf[0];
                uint64 <<= 8;
                uint64 |= buf[1];
                uint64 <<= 8;
                uint64 |= buf[2];
                uint64 <<= 8;
                uint64 |= buf[3];
                uint64 <<= 8;
                uint64 |= buf[4];
                uint64 <<= 8;
                uint64 |= buf[5];
                uint64 <<= 8;
                uint64 |= buf[6];
                uint64 <<= 8;
                uint64 |= buf[7];

                return .{ .uint64 = uint64 };
            },

            .int8 => return .{ .uint8 = @bitCast(buf[0]) },
            .int16 => {
                var uint16: u16 = 0;

                uint16 |= buf[0];
                uint16 <<= 8;
                uint16 |= buf[1];

                return .{ .uint16 = @bitCast(uint16) };
            },
            .int32 => {
                var uint32: u32 = 0;

                uint32 |= buf[0];
                uint32 <<= 8;
                uint32 |= buf[1];
                uint32 <<= 8;
                uint32 |= buf[2];
                uint32 <<= 8;
                uint32 |= buf[3];

                return .{ .uint32 = @bitCast(uint32) };
            },
            .int64 => {
                var uint64: u64 = 0;

                uint64 |= buf[0];
                uint64 <<= 8;
                uint64 |= buf[1];
                uint64 <<= 8;
                uint64 |= buf[2];
                uint64 <<= 8;
                uint64 |= buf[3];
                uint64 <<= 8;
                uint64 |= buf[4];
                uint64 <<= 8;
                uint64 |= buf[5];
                uint64 <<= 8;
                uint64 |= buf[6];
                uint64 <<= 8;
                uint64 |= buf[7];

                return .{ .uint64 = @bitCast(uint64) };
            },

            .float32 => {
                var uint32: u32 = 0;

                uint32 |= buf[0];
                uint32 <<= 8;
                uint32 |= buf[1];
                uint32 <<= 8;
                uint32 |= buf[2];
                uint32 <<= 8;
                uint32 |= buf[3];

                return .{ .float32 = @bitCast(uint32) };
            },
            .float64 => {
                var uint64: u64 = 0;

                uint64 |= buf[0];
                uint64 <<= 8;
                uint64 |= buf[1];
                uint64 <<= 8;
                uint64 |= buf[2];
                uint64 <<= 8;
                uint64 |= buf[3];
                uint64 <<= 8;
                uint64 |= buf[4];
                uint64 <<= 8;
                uint64 |= buf[5];
                uint64 <<= 8;
                uint64 |= buf[6];
                uint64 <<= 8;
                uint64 |= buf[7];

                return .{ .float64 = @bitCast(uint64) };
            },
        }
    }
};

pub const SensorEntry = struct {
    len: u16,
    name: []u8,
    val_type: ValueType,
    value: Value,
};

test "Value parsing" {
    const buf = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };

    const resu8 = Value.fromBytes(.uint8, &buf);
    try std.testing.expectEqual(0xDE, resu8.uint8);

    const resu16 = Value.fromBytes(.uint16, &buf);
    try std.testing.expectEqual(0xDEAD, resu16.uint16);

    const resf32 = Value.fromBytes(.float32, &buf);
    try std.testing.expectEqual(-6.259853398707798e+18, resf32.float32);
}
