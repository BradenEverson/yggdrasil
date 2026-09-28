//! Application level packet

pub const Opcode = enum(u8) {
    nop,
};

op: Opcode = .nop,
payload: []const u8 = undefined,
