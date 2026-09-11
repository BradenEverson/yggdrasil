//! Unique Message types, parsed from raw packets
//! to be used on the app level

const Packet = @import("packet.zig");
const Opcode = Packet.Opcode;

pub const YggMessage = union(Opcode) {
    nop,
};
