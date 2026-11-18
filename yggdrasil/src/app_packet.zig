//! Application level packet

const std = @import("std");
const Address = @import("network_packet.zig").Address;

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
    compact_readings,
    batched_readings,
    reading_series,
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
    root: Address,
    seq: u16,
    hops: u8,

    pub const LEN: usize = 4;

    pub fn parse(payload: []const u8) ?RootAnnouncement {
        if (payload.len < LEN)
            return null;

        return .{
            .root = payload[0],
            .seq = std.mem.readInt(u16, payload[1..3], .big),
            .hops = payload[3],
        };
    }

    pub fn write(ann: RootAnnouncement, buf: *[LEN]u8) void {
        buf[0] = ann.root;
        std.mem.writeInt(u16, buf[1..3], ann.seq, .big);
        buf[3] = ann.hops;
    }
};

pub const TopologyInfo = struct {
    origin: Address,
    seq: u16,
    neighbor_bytes: []const u8,

    pub const HEADER_LEN: usize = 4;

    pub fn parse(payload: []const u8) ?TopologyInfo {
        if (payload.len < HEADER_LEN)
            return null;

        const n: usize = payload[3];
        if (payload.len < HEADER_LEN + n)
            return null;

        return .{
            .origin = payload[0],
            .seq = std.mem.readInt(u16, payload[1..3], .big),
            .neighbor_bytes = payload[HEADER_LEN..][0..n],
        };
    }

    pub fn count(info: TopologyInfo) usize {
        return info.neighbor_bytes.len;
    }

    pub fn neighbor(info: TopologyInfo, i: usize) Address {
        return info.neighbor_bytes[i];
    }

    pub fn write(origin: Address, seq: u16, neighbors: []const Address, buf: []u8) error{NoSpaceLeft}![]u8 {
        const len = HEADER_LEN + neighbors.len;
        if (neighbors.len > std.math.maxInt(u8) or buf.len < len)
            return error.NoSpaceLeft;

        buf[0] = origin;
        std.mem.writeInt(u16, buf[1..3], seq, .big);
        buf[3] = @intCast(neighbors.len);
        @memcpy(buf[HEADER_LEN..][0..neighbors.len], neighbors);

        return buf[0..len];
    }
};

pub const CompactReadings = struct {
    centi_celsius: ?i16 = null,
    deci_hpa: ?u16 = null,
    centi_pct: ?u16 = null,
    gas_log2_q11: ?u16 = null,

    pub const MAX_LEN: usize = 9;
    pub const GAS_Q: f32 = 2048.0;

    const Field = enum(u3) { temperature, pressure, humidity, gas };

    pub fn temperature(celsius: f32) i16 {
        return quantize(i16, celsius * 100.0);
    }

    pub fn pressure(pa: f32) u16 {
        return quantize(u16, pa / 10.0);
    }

    pub fn humidity(pct: f32) u16 {
        return quantize(u16, pct * 100.0);
    }

    pub fn gas(ohm: f32) ?u16 {
        if (!(ohm >= 1.0)) return null;
        return quantize(u16, @log2(ohm) * GAS_Q);
    }

    fn quantize(comptime T: type, x: f32) T {
        if (x != x) return 0;
        const lo: f32 = @floatFromInt(std.math.minInt(T));
        const hi: f32 = @floatFromInt(std.math.maxInt(T));
        return @intFromFloat(@round(std.math.clamp(x, lo, hi)));
    }

    fn bit(field: Field) u8 {
        return @as(u8, 1) << @intFromEnum(field);
    }

    pub fn write(r: CompactReadings, buf: *[MAX_LEN]u8) []const u8 {
        var mask: u8 = 0;
        var n: usize = 1;
        if (r.centi_celsius) |v| {
            mask |= bit(.temperature);
            std.mem.writeInt(i16, buf[n..][0..2], v, .big);
            n += 2;
        }
        if (r.deci_hpa) |v| {
            mask |= bit(.pressure);
            std.mem.writeInt(u16, buf[n..][0..2], v, .big);
            n += 2;
        }
        if (r.centi_pct) |v| {
            mask |= bit(.humidity);
            std.mem.writeInt(u16, buf[n..][0..2], v, .big);
            n += 2;
        }
        if (r.gas_log2_q11) |v| {
            mask |= bit(.gas);
            std.mem.writeInt(u16, buf[n..][0..2], v, .big);
            n += 2;
        }
        buf[0] = mask;
        return buf[0..n];
    }

    pub fn recordLen(mask: u8) ?usize {
        if (mask & ~@as(u8, 0x0F) != 0) return null;
        return 1 + 2 * @as(usize, @popCount(mask));
    }

    pub fn parse(payload: []const u8) ?CompactReadings {
        if (payload.len == 0) return null;
        const mask = payload[0];
        if (payload.len != recordLen(mask) orelse return null) return null;

        var r: CompactReadings = .{};
        var n: usize = 1;
        if (mask & bit(.temperature) != 0) {
            r.centi_celsius = std.mem.readInt(i16, payload[n..][0..2], .big);
            n += 2;
        }
        if (mask & bit(.pressure) != 0) {
            r.deci_hpa = std.mem.readInt(u16, payload[n..][0..2], .big);
            n += 2;
        }
        if (mask & bit(.humidity) != 0) {
            r.centi_pct = std.mem.readInt(u16, payload[n..][0..2], .big);
            n += 2;
        }
        if (mask & bit(.gas) != 0) {
            r.gas_log2_q11 = std.mem.readInt(u16, payload[n..][0..2], .big);
            n += 2;
        }
        return r;
    }

    pub fn toCelsius(r: CompactReadings) ?f32 {
        const v = r.centi_celsius orelse return null;
        return @as(f32, @floatFromInt(v)) / 100.0;
    }

    pub fn toHpa(r: CompactReadings) ?f32 {
        const v = r.deci_hpa orelse return null;
        return @as(f32, @floatFromInt(v)) / 10.0;
    }

    pub fn toPct(r: CompactReadings) ?f32 {
        const v = r.centi_pct orelse return null;
        return @as(f32, @floatFromInt(v)) / 100.0;
    }

    pub fn toOhm(r: CompactReadings) ?f32 {
        const v = r.gas_log2_q11 orelse return null;
        return @exp2(@as(f32, @floatFromInt(v)) / GAS_Q);
    }
};

pub const ReadingBatch = struct {
    bytes: []const u8,

    pub const Entry = struct {
        origin: Address,
        readings: CompactReadings,
    };

    pub fn next(batch: *ReadingBatch) ?Entry {
        if (batch.bytes.len < 2) return null;
        const len = CompactReadings.recordLen(batch.bytes[1]) orelse return null;
        if (batch.bytes.len < 1 + len) return null;
        const readings = CompactReadings.parse(batch.bytes[1..][0..len]) orelse return null;
        const origin = batch.bytes[0];
        batch.bytes = batch.bytes[1 + len ..];
        return .{ .origin = origin, .readings = readings };
    }

    pub fn valid(bytes: []const u8) bool {
        if (bytes.len == 0) return false;
        var batch = ReadingBatch{ .bytes = bytes };
        while (batch.next()) |_| {}
        return batch.bytes.len == 0;
    }
};

pub const ReadingSeries = struct {
    origin: Address,
    mask: u8,
    count: u8,
    interval_s: u16,
    age_s: u16,
    samples: []const u8,

    pub const HEADER_LEN: usize = 6;
    pub const INTERVAL_UNIT_S: u16 = 10;
    pub const MAX_INTERVAL_S: u16 = 255 * INTERVAL_UNIT_S;
    pub const ESCAPE: u8 = 0x80;
    const FIELDS: usize = 4;

    pub const Error = error{ NoSpaceLeft, InvalidSeries };

    pub const Record = struct {
        series: ReadingSeries,
        rest: []const u8,
    };

    pub fn sampleAgeS(series: ReadingSeries, index: usize) u32 {
        return @as(u32, series.age_s) + @as(u32, @intCast(series.count - 1 - index)) * series.interval_s;
    }

    pub fn parseRecord(bytes: []const u8) ?Record {
        if (bytes.len < HEADER_LEN) return null;
        const mask = bytes[1];
        if (mask == 0 or mask & ~@as(u8, 0x0F) != 0) return null;
        const count = bytes[2];
        if (count == 0) return null;

        const fields: usize = @popCount(mask);
        var n: usize = HEADER_LEN + 2 * fields;
        if (bytes.len < n) return null;
        for (1..count) |_| {
            for (0..fields) |_| {
                if (n >= bytes.len) return null;
                n += if (bytes[n] == ESCAPE) 3 else 1;
            }
        }
        if (n > bytes.len) return null;

        return .{
            .series = .{
                .origin = bytes[0],
                .mask = mask,
                .count = count,
                .interval_s = @as(u16, bytes[3]) * INTERVAL_UNIT_S,
                .age_s = std.mem.readInt(u16, bytes[4..6], .big),
                .samples = bytes[HEADER_LEN..n],
            },
            .rest = bytes[n..],
        };
    }

    pub fn valid(bytes: []const u8) bool {
        if (bytes.len == 0) return false;
        var rest = bytes;
        while (rest.len != 0) rest = (parseRecord(rest) orelse return false).rest;
        return true;
    }

    pub fn iterator(series: ReadingSeries) Iterator {
        return .{ .series = series };
    }

    pub const Iterator = struct {
        series: ReadingSeries,
        index: usize = 0,
        pos: usize = 0,
        values: [FIELDS]u16 = @splat(0),

        pub fn next(it: *Iterator) ?CompactReadings {
            if (it.index >= it.series.count) return null;
            const b = it.series.samples;
            var r: CompactReadings = .{};
            for (0..FIELDS) |f| {
                if (it.series.mask & (@as(u8, 1) << @intCast(f)) == 0) continue;
                if (it.index == 0 or b[it.pos] == ESCAPE) {
                    if (it.index != 0) it.pos += 1;
                    it.values[f] = std.mem.readInt(u16, b[it.pos..][0..2], .big);
                    it.pos += 2;
                } else {
                    const delta: i8 = @bitCast(b[it.pos]);
                    it.values[f] +%= @bitCast(@as(i16, delta));
                    it.pos += 1;
                }
                setRaw(&r, f, it.values[f]);
            }
            it.index += 1;
            return r;
        }
    };

    pub fn write(origin: Address, interval_s: u16, age_s: u16, samples: []const CompactReadings, buf: []u8) Error![]u8 {
        if (samples.len == 0 or samples.len > std.math.maxInt(u8)) return error.InvalidSeries;
        if (interval_s % INTERVAL_UNIT_S != 0 or interval_s > MAX_INTERVAL_S) return error.InvalidSeries;

        var mask: u8 = 0;
        for (0..FIELDS) |f| {
            if (raw(samples[0], f) != null) mask |= @as(u8, 1) << @intCast(f);
        }
        if (mask == 0) return error.InvalidSeries;

        if (buf.len < HEADER_LEN) return error.NoSpaceLeft;
        buf[0] = origin;
        buf[1] = mask;
        buf[2] = @intCast(samples.len);
        buf[3] = @intCast(interval_s / INTERVAL_UNIT_S);
        std.mem.writeInt(u16, buf[4..6], age_s, .big);

        var n: usize = HEADER_LEN;
        var prev: [FIELDS]u16 = @splat(0);
        for (samples, 0..) |sample, i| {
            for (0..FIELDS) |f| {
                if (mask & (@as(u8, 1) << @intCast(f)) == 0) continue;
                const v = raw(sample, f) orelse prev[f];
                const delta: i16 = @bitCast(v -% prev[f]);
                if (i != 0 and delta >= -127 and delta <= 127) {
                    if (buf.len < n + 1) return error.NoSpaceLeft;
                    buf[n] = @bitCast(@as(i8, @intCast(delta)));
                    n += 1;
                } else {
                    const extra: usize = if (i == 0) 0 else 1;
                    if (buf.len < n + extra + 2) return error.NoSpaceLeft;
                    if (i != 0) buf[n] = ESCAPE;
                    std.mem.writeInt(u16, buf[n + extra ..][0..2], v, .big);
                    n += extra + 2;
                }
                prev[f] = v;
            }
        }
        return buf[0..n];
    }

    fn raw(r: CompactReadings, field: usize) ?u16 {
        return switch (field) {
            0 => if (r.centi_celsius) |v| @as(u16, @bitCast(v)) else null,
            1 => r.deci_hpa,
            2 => r.centi_pct,
            else => r.gas_log2_q11,
        };
    }

    fn setRaw(r: *CompactReadings, field: usize, v: u16) void {
        switch (field) {
            0 => r.centi_celsius = @bitCast(v),
            1 => r.deci_hpa = v,
            2 => r.centi_pct = v,
            else => r.gas_log2_q11 = v,
        }
    }
};

pub const SeriesBatch = struct {
    bytes: []const u8,

    pub fn next(batch: *SeriesBatch) ?ReadingSeries {
        if (batch.bytes.len == 0) return null;
        const record = ReadingSeries.parseRecord(batch.bytes) orelse return null;
        batch.bytes = record.rest;
        return record.series;
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
    (RootAnnouncement{ .root = 0xBE, .seq = 513, .hops = 4 }).write(&buf);

    const ann = RootAnnouncement.parse(&buf).?;
    try std.testing.expectEqual(@as(Address, 0xBE), ann.root);
    try std.testing.expectEqual(@as(u16, 513), ann.seq);
    try std.testing.expectEqual(@as(u8, 4), ann.hops);
    try std.testing.expect(RootAnnouncement.parse(buf[0..3]) == null);
}

test "Topology info round trip" {
    var buf: [32]u8 = undefined;
    const bytes = try TopologyInfo.write(0x12, 7, &.{ 0xBE, 3 }, &buf);
    try std.testing.expectEqual(@as(usize, 6), bytes.len);

    const info = TopologyInfo.parse(bytes).?;
    try std.testing.expectEqual(@as(Address, 0x12), info.origin);
    try std.testing.expectEqual(@as(u16, 7), info.seq);
    try std.testing.expectEqual(@as(usize, 2), info.count());
    try std.testing.expectEqual(@as(Address, 0xBE), info.neighbor(0));
    try std.testing.expectEqual(@as(Address, 3), info.neighbor(1));

    try std.testing.expect(TopologyInfo.parse(bytes[0..5]) == null);
    try std.testing.expectError(error.NoSpaceLeft, TopologyInfo.write(1, 1, &.{ 1, 2 }, buf[0..5]));
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

test "Compact readings round trip within quantization" {
    const r: CompactReadings = .{
        .centi_celsius = CompactReadings.temperature(24.37),
        .deci_hpa = CompactReadings.pressure(100_418.0),
        .centi_pct = CompactReadings.humidity(27.36),
        .gas_log2_q11 = CompactReadings.gas(56_164.0),
    };

    var buf: [CompactReadings.MAX_LEN]u8 = undefined;
    const bytes = r.write(&buf);
    try std.testing.expectEqual(@as(usize, 9), bytes.len);
    try std.testing.expectEqual(@as(u8, 0x0F), bytes[0]);

    const back = CompactReadings.parse(bytes).?;
    try std.testing.expectApproxEqAbs(@as(f32, 24.37), back.toCelsius().?, 0.005);
    try std.testing.expectApproxEqAbs(@as(f32, 1004.18), back.toHpa().?, 0.05);
    try std.testing.expectApproxEqAbs(@as(f32, 27.36), back.toPct().?, 0.005);
    try std.testing.expectApproxEqRel(@as(f32, 56_164.0), back.toOhm().?, 0.0005);
}

test "Compact readings skip missing fields" {
    const r: CompactReadings = .{
        .centi_celsius = CompactReadings.temperature(-12.5),
        .centi_pct = CompactReadings.humidity(80.0),
    };

    var buf: [CompactReadings.MAX_LEN]u8 = undefined;
    const bytes = r.write(&buf);
    try std.testing.expectEqualSlices(u8, &.{ 0x05, 0xFB, 0x1E, 0x1F, 0x40 }, bytes);

    const back = CompactReadings.parse(bytes).?;
    try std.testing.expectEqual(@as(?i16, -1250), back.centi_celsius);
    try std.testing.expectEqual(@as(?u16, null), back.deci_hpa);
    try std.testing.expectEqual(@as(?u16, 8000), back.centi_pct);
    try std.testing.expectEqual(@as(?u16, null), back.gas_log2_q11);
}

test "Compact readings reject malformed payloads" {
    try std.testing.expect(CompactReadings.parse(&.{}) == null);
    try std.testing.expect(CompactReadings.parse(&.{ 0x01, 0x00 }) == null);
    try std.testing.expect(CompactReadings.parse(&.{ 0x01, 0x00, 0x00, 0x00 }) == null);
    try std.testing.expect(CompactReadings.parse(&.{ 0x10, 0x00, 0x00 }) == null);
}

test "Reading batches walk every entry and reject trailing garbage" {
    const bytes = [_]u8{ 4, 0x01, 0x09, 0xC4, 7, 0x05, 0xFB, 0x1E, 0x1F, 0x40 };
    var batch = ReadingBatch{ .bytes = &bytes };

    const first = batch.next().?;
    try std.testing.expectEqual(@as(Address, 4), first.origin);
    try std.testing.expectEqual(@as(?i16, 2500), first.readings.centi_celsius);

    const second = batch.next().?;
    try std.testing.expectEqual(@as(Address, 7), second.origin);
    try std.testing.expectEqual(@as(?u16, 8000), second.readings.centi_pct);
    try std.testing.expect(batch.next() == null);

    try std.testing.expect(ReadingBatch.valid(&bytes));
    try std.testing.expect(!ReadingBatch.valid(bytes[0..9]));
    try std.testing.expect(!ReadingBatch.valid(&.{}));
    try std.testing.expect(!ReadingBatch.valid(&.{ 4, 0x10, 0, 0 }));
}

fn sampleAt(c: f32, hpa: f32, pct: f32) CompactReadings {
    return .{
        .centi_celsius = CompactReadings.temperature(c),
        .deci_hpa = CompactReadings.pressure(hpa * 100.0),
        .centi_pct = CompactReadings.humidity(pct),
    };
}

test "Reading series round trips with small deltas and escapes" {
    const samples = [_]CompactReadings{
        sampleAt(21.00, 1004.2, 55.00),
        sampleAt(21.05, 1004.2, 54.90),
        sampleAt(23.50, 1004.1, 54.80),
        sampleAt(-3.20, 1004.3, 61.00),
        sampleAt(-3.21, 1004.3, 60.99),
    };
    var buf: [64]u8 = undefined;
    const bytes = try ReadingSeries.write(7, 60, 3, &samples, &buf);
    try std.testing.expectEqual(@as(usize, ReadingSeries.HEADER_LEN + 6 + 3 + 5 + 7 + 3), bytes.len);

    const record = ReadingSeries.parseRecord(bytes).?;
    try std.testing.expectEqual(@as(usize, 0), record.rest.len);
    const series = record.series;
    try std.testing.expectEqual(@as(Address, 7), series.origin);
    try std.testing.expectEqual(@as(u8, 5), series.count);
    try std.testing.expectEqual(@as(u16, 60), series.interval_s);
    try std.testing.expectEqual(@as(u32, 243), series.sampleAgeS(0));
    try std.testing.expectEqual(@as(u32, 3), series.sampleAgeS(4));

    var it = series.iterator();
    for (samples) |want| {
        const got = it.next().?;
        try std.testing.expectEqual(want.centi_celsius, got.centi_celsius);
        try std.testing.expectEqual(want.deci_hpa, got.deci_hpa);
        try std.testing.expectEqual(want.centi_pct, got.centi_pct);
        try std.testing.expectEqual(@as(?u16, null), got.gas_log2_q11);
    }
    try std.testing.expect(it.next() == null);
}

test "Reading series repeat a missing field and reject bad input" {
    var later = sampleAt(20.0, 1000.0, 50.0);
    later.deci_hpa = null;
    const samples = [_]CompactReadings{ sampleAt(20.0, 1000.0, 50.0), later };
    var buf: [32]u8 = undefined;
    const bytes = try ReadingSeries.write(1, 60, 0, &samples, &buf);
    var it = ReadingSeries.parseRecord(bytes).?.series.iterator();
    _ = it.next();
    try std.testing.expectEqual(CompactReadings.pressure(100_000.0), it.next().?.deci_hpa.?);

    try std.testing.expectError(error.InvalidSeries, ReadingSeries.write(1, 65, 0, &samples, &buf));
    try std.testing.expectError(error.InvalidSeries, ReadingSeries.write(1, 60, 0, &.{}, &buf));
    try std.testing.expectError(error.NoSpaceLeft, ReadingSeries.write(1, 60, 0, &samples, buf[0..8]));
    try std.testing.expect(!ReadingSeries.valid(bytes[0 .. bytes.len - 1]));
    try std.testing.expect(!ReadingSeries.valid(&.{}));
}

test "Series batches walk concatenated records" {
    const a = [_]CompactReadings{ sampleAt(20.0, 1000.0, 50.0), sampleAt(20.1, 1000.0, 50.0) };
    const b = [_]CompactReadings{sampleAt(10.0, 990.0, 80.0)};
    var buf: [64]u8 = undefined;
    const first = try ReadingSeries.write(4, 60, 0, &a, &buf);
    const second = try ReadingSeries.write(9, 60, 0, &b, buf[first.len..]);
    const both = buf[0 .. first.len + second.len];
    try std.testing.expect(ReadingSeries.valid(both));

    var batch = SeriesBatch{ .bytes = both };
    try std.testing.expectEqual(@as(Address, 4), batch.next().?.origin);
    try std.testing.expectEqual(@as(Address, 9), batch.next().?.origin);
    try std.testing.expect(batch.next() == null);
}

test "Compact quantization clamps out of range values" {
    try std.testing.expectEqual(@as(i16, std.math.maxInt(i16)), CompactReadings.temperature(1000.0));
    try std.testing.expectEqual(@as(u16, 0), CompactReadings.humidity(-5.0));
    try std.testing.expectEqual(@as(?u16, null), CompactReadings.gas(0.0));
    try std.testing.expectEqual(@as(?u16, null), CompactReadings.gas(std.math.nan(f32)));
    try std.testing.expectEqual(@as(i16, 0), CompactReadings.temperature(std.math.nan(f32)));
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
