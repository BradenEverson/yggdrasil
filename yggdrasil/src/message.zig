//! Unique Message types, parsed from raw packets
//! to be used on the app level

const std = @import("std");

const Packet = @import("packet.zig");
const Opcode = Packet.Opcode;

pub const YggMessage = union(Opcode) {
    nop,
    ack: AckMessage,
    nack: NackMessage,

    pub fn fromPacket(packet: Packet) ?YggMessage {
        return ret: switch (packet.op) {
            .nop => .nop,
            .ack => switch (packet.payload[0]) {
                0x00 => .{ .ack = .general },
                else => null,
            },
            .nack => {
                break :ret null;
            },
        };
    }
};

pub const NackReason = enum(u8) {
    checksum_mismatch,
};

pub const NackMessage = union(NackReason) {
    checksum_mismatch,
};

pub const AckType = enum(u8) {
    general,
    with_data,
};

pub const AckMessage = union(AckType) {
    general,
    with_data: []u8,
};

test "Simple packet to message" {
    const msg: ?YggMessage = .fromPacket(.{});

    try std.testing.expectEqual(YggMessage.nop, msg.?);
}

test "ack" {
    const payload = [1]u8{0x00};
    const ack = Packet{
        .op = .ack,
        .payload = &payload,
    };
    const msg: ?YggMessage = .fromPacket(ack);

    try std.testing.expectEqual(YggMessage{ .ack = .general }, msg.?);
}
