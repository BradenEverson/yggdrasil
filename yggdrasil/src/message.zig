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
                @intFromEnum(AckType.general) => .{ .ack = .general },

                @intFromEnum(AckType.with_data) => .{
                    .ack = .{ .with_data = packet.payload[1..] },
                },
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
    with_data: []const u8,
};

test "Simple packet to message" {
    const msg: ?YggMessage = .fromPacket(.{});

    try std.testing.expectEqual(YggMessage.nop, msg.?);
}

test "acks" {
    const payload = [1]u8{0x00};
    const ack = Packet{
        .op = .ack,
        .payload = &payload,
    };
    var msg: ?YggMessage = .fromPacket(ack);

    try std.testing.expectEqual(YggMessage{ .ack = .general }, msg.?);

    const payload2 = [6]u8{ 0x01, 'h', 'e', 'l', 'l', 'o' };
    const ack_with_data = Packet{
        .op = .ack,
        .payload = &payload2,
    };
    msg = .fromPacket(ack_with_data);

    try std.testing.expectEqualSlices(u8, "hello", msg.?.ack.with_data);
}
