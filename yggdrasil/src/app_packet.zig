//! Application level packet

const std = @import("std");

pub const Opcode = enum(u8) {
    nop,
    sensor_readings,
};

op: Opcode = .nop,
payload: []const u8 = undefined,

pub const SensorReadingStream = struct {
    buf: []const u8,

    pub fn next(stream: *SensorReadingStream) ?SensorEntry {
        // Must have at least the space for length and the
        // reading type
        if (stream.buf.len < 2)
            return null;

        const len = stream.buf[0];

        stream.buf = stream.buf[1..];

        if (stream.buf.len < len)
            return null;

        const val_type: ValueType = @enumFromInt(stream.buf[0]);

        stream.buf = stream.buf[1..];

        const name_len = len - 1 - val_type.byteCount();

        const name = stream.buf[0..name_len];

        stream.buf = stream.buf[name_len..];

        const value = Value.fromBytes(val_type, stream.buf);

        stream.buf = stream.buf[val_type.byteCount()..];

        return .{
            .name = name,
            .value = value,
        };
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

    pub fn byteCount(val: ValueType) usize {
        return switch (val) {
            .uint8, .int8 => 1,
            .uint16, .int16 => 2,
            .uint32, .int32, .float32 => 4,
            .uint64, .int64, .float64 => 8,
        };
    }
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

            .int8 => return .{ .int8 = @bitCast(buf[0]) },
            .int16 => {
                var uint16: u16 = 0;

                uint16 |= buf[0];
                uint16 <<= 8;
                uint16 |= buf[1];

                return .{ .int16 = @bitCast(uint16) };
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

                return .{ .int32 = @bitCast(uint32) };
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

                return .{ .int64 = @bitCast(uint64) };
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
    name: []const u8,
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

test "Sensor stream" {
    const sensor_data = [_]u8{
        // First Packet
        9, // len
        2, // reading type: u32
        't', // Name
        'e',
        's',
        't',
        0xDE, // Value
        0xAD,
        0xBE,
        0xEF,

        // Second Packet
        8, // len
        4, // reading type: i8
        'n', // name
        'u',
        'm',
        'b',
        'e',
        'r',
        0xFF, // val

        // Unfinished packet, should return null
        100,
        0,
    };

    var streamer = SensorReadingStream{
        .buf = &sensor_data,
    };

    var packet = streamer.next().?;
    var expected: SensorEntry = .{
        .name = "test",
        .value = .{ .uint32 = 0xDEADBEEF },
    };

    try std.testing.expectEqualSlices(u8, expected.name, packet.name);
    try std.testing.expectEqual(expected.value, packet.value);

    packet = streamer.next().?;
    expected = .{
        .name = "number",
        .value = .{ .int8 = -1 },
    };

    try std.testing.expectEqualSlices(u8, expected.name, packet.name);
    try std.testing.expectEqual(expected.value, packet.value);

    try std.testing.expectEqual(null, streamer.next());
}
