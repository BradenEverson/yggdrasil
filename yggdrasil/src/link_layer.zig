//! Link Layer bit checks for if a message is new, and if a message we sent was received
//!
//! Uses a 1-bit sliding window (SN / NESN), per neighbor:
//!  - `sn`   is the sequence bit stamped on the packet we are currently sending
//!  - `nesn` is the sequence bit we expect on the next new packet from them
//!
//! Every packet we send carries our `sn` and `nesn`, so every packet we receive
//! from a neighbor both acknowledges (or not) our in-flight packet and tells us
//! if their packet is new or a re-transmission.

const std = @import("std");
const Yggdrasil = @import("root.zig").Yggdrasil;
const NetworkPacket = @import("network_packet.zig");
const routing = @import("routing.zig");

/// Processes the SN / NESN bits of a packet received from the neighbor
/// described by `mq_map`.
///
/// If the neighbor's NESN differs from our SN, they've received our in-flight
/// packet: it is removed from the tx buffer and our SN flips so the next packet
/// is sent with the new sequence bit. Otherwise the tx buffer is kept so it
/// gets re-transmitted.
///
/// Returns true if the received packet is new (its SN matches our NESN), in
/// which case our NESN flips to acknowledge it. Returns false for a duplicate.
pub fn linkLayerProcess(
    ygg: *Yggdrasil,
    mq_map: *routing.MessageQueueMap,
    sn: bool,
    nesn: bool,
) bool {
    processAck(ygg, mq_map, nesn);

    // Whether it's new or a re-transmission (meaning our last ack was lost),
    // the neighbor needs to hear back from us
    mq_map.ack_pending = true;

    // New data from the neighbor
    if (sn == mq_map.nesn) {
        mq_map.nesn = !mq_map.nesn;
        return true;
    }

    return false;
}

/// A link-only packet carries nothing but SN / NESN for a direct neighbor: no
/// payload, and none of the app level ack / nack or broadcast flags. They don't
/// consume a sequence number on either side, so they never need acking themselves
pub fn isLinkOnly(packet: *const NetworkPacket) bool {
    return packet.len == 0 and !packet.ack and !packet.nack and !packet.broadcast;
}

/// Handles only the acknowledgement half of the link layer. Used directly for
/// link-only packets (see `isLinkOnly`)
pub fn processAck(ygg: *Yggdrasil, mq_map: *routing.MessageQueueMap, nesn: bool) void {
    // Once flipped, our SN matches their NESN again, so duplicate acks are no-ops
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

    // Re-transmission of the same packet
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

    // Peer hasn't seen our packet (nesn == our sn), keep re-transmitting
    _ = linkLayerProcess(&ygg, &map, false, false);
    try std.testing.expect(mq.tx_buffers[0] != null);
    try std.testing.expect(!map.sn);

    // Peer acked it
    _ = linkLayerProcess(&ygg, &map, true, true);
    try std.testing.expect(mq.tx_buffers[0] == null);
    try std.testing.expect(map.sn);

    // A second packet with the same nesn shouldn't double-ack anything
    _ = linkLayerProcess(&ygg, &map, false, true);
    try std.testing.expect(map.sn);
}
