//! Application level packet

const std = @import("std");

pub const Opcode = enum(u8) {
    /// Message sent by a node who just woke up
    /// All neighbors that can hear the message
    /// will reply with an ack. This helps the
    /// node learn it's neighbors immediately
    /// before then being able to request topology
    /// information
    ///
    /// This also helps other nodes learn routing
    /// to this new node!
    hello,
    /// Signify that the sender is a root that data should
    /// be streamed to
    im_a_root,
    /// Message from a root to enable a device's stream
    /// of sensor data. Sender payload will include a
    /// minimum latency the root would like, an ack will
    /// tell the original sender what the selected frequency
    /// of stream was
    configure_stream,
    /// A list of all connections that the source
    /// node has with all other nodes it can see
    ///
    /// Used for creating the routing table
    topology_info,
    /// The true application level data, a collection of
    /// sensor readings from this node to a central hub
    sensor_readings,
};

op: Opcode = .hello,
payload: []const u8 = undefined,

const AppPacket = @This();

pub fn parse(bytes: []const u8) ?AppPacket {
    if (bytes.len == 0)
        return null;

    const op = std.enums.fromInt(Opcode, bytes[0]) orelse return null;

    return .{
        .op = op,
        .payload = bytes[1..],
    };
}

pub fn write(app: AppPacket, buf: []u8) error{NoSpaceLeft}![]u8 {
    if (buf.len < app.payload.len + 1)
        return error.NoSpaceLeft;

    buf[0] = @backingInt(app.op);
    @memcpy(buf[1 .. 1 + app.payload.len], app.payload);

    return buf[0 .. 1 + app.payload.len];
}

pub const RootAnnouncement = struct {
    root: u16,
    seq: u16,
    hops: u8,

    pub const LEN: usize = 5;

    pub fn parse(payload: []const u8) ?RootAnnouncement {
        if (payload.len < LEN)
            return null;

        return .{
            .root = std.mem.readInt(u16, payload[0..2], .big),
            .seq = std.mem.readInt(u16, payload[2..4], .big),
            .hops = payload[4],
        };
    }

    pub fn write(ann: RootAnnouncement, buf: *[LEN]u8) void {
        std.mem.writeInt(u16, buf[0..2], ann.root, .big);
        std.mem.writeInt(u16, buf[2..4], ann.seq, .big);
        buf[4] = ann.hops;
    }
};

pub const TopologyInfo = struct {
    origin: u16,
    seq: u16,
    neighbor_bytes: []const u8,

    pub const HEADER_LEN: usize = 5;

    pub fn parse(payload: []const u8) ?TopologyInfo {
        if (payload.len < HEADER_LEN)
            return null;

        const n: usize = payload[4];
        if (payload.len < HEADER_LEN + n * 2)
            return null;

        return .{
            .origin = std.mem.readInt(u16, payload[0..2], .big),
            .seq = std.mem.readInt(u16, payload[2..4], .big),
            .neighbor_bytes = payload[HEADER_LEN..][0 .. n * 2],
        };
    }

    pub fn count(info: TopologyInfo) usize {
        return info.neighbor_bytes.len / 2;
    }

    pub fn neighbor(info: TopologyInfo, i: usize) u16 {
        return std.mem.readInt(u16, info.neighbor_bytes[i * 2 ..][0..2], .big);
    }

    pub fn write(origin: u16, seq: u16, neighbors: []const u16, buf: []u8) error{NoSpaceLeft}![]u8 {
        const len = HEADER_LEN + neighbors.len * 2;
        if (neighbors.len > std.math.maxInt(u8) or buf.len < len)
            return error.NoSpaceLeft;

        std.mem.writeInt(u16, buf[0..2], origin, .big);
        std.mem.writeInt(u16, buf[2..4], seq, .big);
        buf[4] = @intCast(neighbors.len);
        for (neighbors, 0..) |addr, i|
            std.mem.writeInt(u16, buf[HEADER_LEN + i * 2 ..][0..2], addr, .big);

        return buf[0..len];
    }
};

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

        const val_type: ValueType = @fromBackingInt(@intCast(stream.buf[0]));

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

pub const SensorReadingWriter = struct {
    buf: []u8,
    len: usize = 0,

    pub fn add(writer: *SensorReadingWriter, name: []const u8, value: Value) error{NoSpaceLeft}!void {
        const val_type = std.meta.activeTag(value);
        const entry_len = 1 + name.len + val_type.byteCount();

        if (entry_len > std.math.maxInt(u8) or writer.len + 1 + entry_len > writer.buf.len)
            return error.NoSpaceLeft;

        const out = writer.buf[writer.len..][0 .. 1 + entry_len];
        out[0] = @intCast(entry_len);
        out[1] = @backingInt(val_type);
        @memcpy(out[2..][0..name.len], name);
        value.toBytes(out[2 + name.len ..]);

        writer.len += 1 + entry_len;
    }

    pub fn written(writer: *const SensorReadingWriter) []const u8 {
        return writer.buf[0..writer.len];
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

    pub fn toBytes(value: Value, buf: []u8) void {
        switch (value) {
            inline else => |v| {
                const Bits = switch (@sizeOf(@TypeOf(v))) {
                    1 => u8,
                    2 => u16,
                    4 => u32,
                    8 => u64,
                    else => unreachable,
                };
                std.mem.writeInt(Bits, buf[0..@sizeOf(Bits)], @bitCast(v), .big);
            },
        }
    }

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

test "App packet round trip" {
    var buf: [8]u8 = undefined;
    const bytes = try (AppPacket{ .op = .topology_info, .payload = &.{ 1, 2 } }).write(&buf);

    const parsed = AppPacket.parse(bytes).?;
    try std.testing.expectEqual(Opcode.topology_info, parsed.op);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, parsed.payload);

    try std.testing.expect(AppPacket.parse(&.{}) == null);
    try std.testing.expect(AppPacket.parse(&.{0xFF}) == null);
}

test "Root announcement round trip" {
    var buf: [RootAnnouncement.LEN]u8 = undefined;
    (RootAnnouncement{ .root = 0xBEEF, .seq = 513, .hops = 4 }).write(&buf);

    const ann = RootAnnouncement.parse(&buf).?;
    try std.testing.expectEqual(@as(u16, 0xBEEF), ann.root);
    try std.testing.expectEqual(@as(u16, 513), ann.seq);
    try std.testing.expectEqual(@as(u8, 4), ann.hops);
    try std.testing.expect(RootAnnouncement.parse(buf[0..4]) == null);
}

test "Topology info round trip" {
    var buf: [32]u8 = undefined;
    const bytes = try TopologyInfo.write(0x0102, 7, &.{ 0xBEEF, 3 }, &buf);
    try std.testing.expectEqual(@as(usize, 9), bytes.len);

    const info = TopologyInfo.parse(bytes).?;
    try std.testing.expectEqual(@as(u16, 0x0102), info.origin);
    try std.testing.expectEqual(@as(u16, 7), info.seq);
    try std.testing.expectEqual(@as(usize, 2), info.count());
    try std.testing.expectEqual(@as(u16, 0xBEEF), info.neighbor(0));
    try std.testing.expectEqual(@as(u16, 3), info.neighbor(1));

    try std.testing.expect(TopologyInfo.parse(bytes[0..8]) == null);
    try std.testing.expectError(error.NoSpaceLeft, TopologyInfo.write(1, 1, &.{ 1, 2 }, buf[0..8]));
}

test "Sensor writer round trips through the stream" {
    var buf: [64]u8 = undefined;
    var writer = SensorReadingWriter{ .buf = &buf };

    try writer.add("temp_f", .{ .float32 = 71.25 });
    try writer.add("pwr_mw", .{ .uint16 = 512 });
    try writer.add("delta", .{ .int64 = -3 });

    var stream = SensorReadingStream{ .buf = writer.written() };

    var entry = stream.next().?;
    try std.testing.expectEqualSlices(u8, "temp_f", entry.name);
    try std.testing.expectEqual(Value{ .float32 = 71.25 }, entry.value);

    entry = stream.next().?;
    try std.testing.expectEqualSlices(u8, "pwr_mw", entry.name);
    try std.testing.expectEqual(Value{ .uint16 = 512 }, entry.value);

    entry = stream.next().?;
    try std.testing.expectEqualSlices(u8, "delta", entry.name);
    try std.testing.expectEqual(Value{ .int64 = -3 }, entry.value);

    try std.testing.expect(stream.next() == null);

    var small: [8]u8 = undefined;
    var full = SensorReadingWriter{ .buf = &small };
    try std.testing.expectError(error.NoSpaceLeft, full.add("too_long", .{ .uint8 = 1 }));
}

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
