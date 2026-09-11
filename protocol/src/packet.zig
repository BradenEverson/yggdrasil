//! Raw Packet structure

pub const Opcode = enum(u8) { nop };

op: Opcode = .nop,
len: u16 = 0,
payload: []u8 = undefined,
crc: u16 = 0,
