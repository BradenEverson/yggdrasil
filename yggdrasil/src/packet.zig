//! Raw Packet structure

pub const Opcode = enum(u8) {
    nop,
    ack,
    nack,
    OPCODE_MAX,
};

pub fn payloadSize(comptime op: Opcode) comptime_int {
    return switch (op) {
        .nop => 0,
        .ack => 4,
        .nack => 1,
        .OPCODE_MAX => unreachable,
    };
}

pub fn largestPayload() comptime_int {
    var max: comptime_int = 0;

    comptime for (0..@intFromEnum(Opcode.OPCODE_MAX)) |i| {
        const size = payloadSize(@enumFromInt(i));
        if (size > max) {
            max = size;
        }
    };

    return max;
}

op: Opcode = .nop,
len: u16 = 0,
payload: []u8 = undefined,
crc: u16 = 0,

test {
    _ = @import("packet/crc.zig");
}
