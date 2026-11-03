const std = @import("std");
const Yggdrasil = @import("root.zig").Yggdrasil;
const NetworkPacket = @import("network_packet.zig");
const routing = @import("routing.zig");

pub fn linkLayerProcess(
    ygg: *Yggdrasil,
    mq_map: *routing.MessageQueueMap,
    sn: bool,
    nesn: bool,
) bool {
    processAck(ygg, mq_map, nesn);

    mq_map.ack_pending = true;

    if (sn == mq_map.nesn) {
        mq_map.nesn = !mq_map.nesn;
        return true;
    }

    return false;
}

pub fn isLinkOnly(packet: *const NetworkPacket) bool {
    return packet.len == 0 and !packet.ack and !packet.nack and !packet.broadcast;
}

pub fn processAck(ygg: *Yggdrasil, mq_map: *routing.MessageQueueMap, nesn: bool) void {
    if (nesn != mq_map.sn) {
        ygg.outgoing_packets.ackTxBuffer(mq_map.mq_idx);
        mq_map.sn = !mq_map.sn;
    }
}

const TestRuntime = struct {
    fn cb(_: @import("root.zig").NetworkPacket) void {}
    fn read(buf: []u8) @import("root.zig").YggdrasilError![]u8 {
        return buf[0..0];
    }
    fn write(_: []u8) @import("root.zig").YggdrasilError!void {}
};

fn testYgg() Yggdrasil {
    return .{
        .read_bytes_fn = TestRuntime.read,
        .write_bytes_fn = TestRuntime.write,
        .result_cb = TestRuntime.cb,
    };
}

test "new packets flip nesn, duplicates are rejected" {
    var ygg = testYgg();
    var map = routing.MessageQueueMap{};

    try std.testing.expect(linkLayerProcess(&ygg, &map, false, false));
    try std.testing.expect(map.nesn);

    try std.testing.expect(!linkLayerProcess(&ygg, &map, false, false));
    try std.testing.expect(map.nesn);

    try std.testing.expect(linkLayerProcess(&ygg, &map, true, false));
    try std.testing.expect(!map.nesn);
}

test "ack clears tx buffer and flips sn" {
    var ygg = testYgg();
    var map = routing.MessageQueueMap{};
    const mq = &ygg.outgoing_packets;
    mq.registered_nodes = 1;

    try mq.pushMessage(0, .{ .to = 7 }, 0);
    _ = mq.txBuffer(0);

    _ = linkLayerProcess(&ygg, &map, false, false);
    try std.testing.expect(mq.tx_buffers[0] != null);
    try std.testing.expect(!map.sn);

    _ = linkLayerProcess(&ygg, &map, true, true);
    try std.testing.expect(mq.tx_buffers[0] == null);
    try std.testing.expect(map.sn);

    _ = linkLayerProcess(&ygg, &map, false, true);
    try std.testing.expect(map.sn);
}
