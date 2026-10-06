//! Application level packet

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

        const len: u16 = 0;
        len |= len_msb << 8;
        len |= len_lsb << 0;

        const val_type: ValueType = @enumFromInt(stream.buf[2]);
        _ = val_type;

        stream.buf = stream.buf[3..];

        const name_len_msb = stream.buf[0];
        const name_len_lsb = stream.buf[1];

        const name_len: u16 = 0;
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
};

pub const SensorEntry = struct {
    len: u16,
    name: []u8,
    val_type: ValueType,
    value: Value,
};
