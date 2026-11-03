//! Message queue for outgoing packets
//!
//! priotity queues for a list of registered neighbor nodes
//! the top level Yggdrasil package can then be polled for
//! the highest priority packet to send

const PriorityQueue = @import("message_queue/priority_queue.zig").PriorityQueue;
const NetworkPacket = @import("network_packet.zig");

pub const MAX_NEIGHBORS: usize = 64;

/// Maximum size of a single message queue, messages
/// need to be acked at the link layer level before they
/// are popped from the mq btw ;)
pub const MAX_MESSAGE_QUEUE_LENGTH: usize = 16;

const MessageSlots = [MAX_NEIGHBORS]PriorityQueue(NetworkPacket, MAX_MESSAGE_QUEUE_LENGTH);

pub const PRIORITY_LOW: u8 = 10;
pub const PRIORITY_HIGH: u8 = 0;

slots: MessageSlots = @splat(.{}),
/// In-flight packet per neighbor. A packet is popped from its slot into here
/// and re-transmitted until the link layer sees it acknowledged
tx_buffers: [MAX_NEIGHBORS]?NetworkPacket = @splat(null),
registered_nodes: usize = 0,
cursor: usize = 0,

const MessageQueue = @This();

pub fn pushMessage(mq: *MessageQueue, slot: usize, msg: NetworkPacket, priority: u8) !void {
    try mq.slots[slot].push(msg, priority);
}

pub fn allEmpty(mq: *const MessageQueue) bool {
    for (0..mq.registered_nodes) |i| {
        if (!mq.slots[i].isEmpty() or mq.tx_buffers[i] != null)
            return false;
    }

    return true;
}

pub fn txBuffer(mq: *MessageQueue, slot: usize) ?*NetworkPacket {
    if (mq.tx_buffers[slot] == null)
        mq.tx_buffers[slot] = mq.slots[slot].pop();

    if (mq.tx_buffers[slot]) |*packet|
        return packet;

    return null;
}

pub fn ackTxBuffer(mq: *MessageQueue, slot: usize) void {
    mq.tx_buffers[slot] = null;
}

pub fn roundRobinTx(mq: *MessageQueue) ?usize {
    if (mq.registered_nodes == 0)
        return null;

    if (mq.cursor >= mq.registered_nodes)
        mq.cursor = 0;

    for (0..mq.registered_nodes) |_| {
        const slot = mq.cursor;
        mq.cursor = (mq.cursor + 1) % mq.registered_nodes;

        if (mq.txBuffer(slot) != null)
            return slot;
    }

    return null;
}

test "tx buffer holds packet until acked" {
    const std = @import("std");
    var mq = MessageQueue{ .registered_nodes = 1 };

    try mq.pushMessage(0, .{ .to = 1 }, PRIORITY_LOW);
    try mq.pushMessage(0, .{ .to = 2 }, PRIORITY_LOW);

    try std.testing.expectEqual(@as(u16, 1), mq.txBuffer(0).?.to);
    try std.testing.expectEqual(@as(u16, 1), mq.txBuffer(0).?.to);

    mq.ackTxBuffer(0);
    try std.testing.expectEqual(@as(u16, 2), mq.txBuffer(0).?.to);

    mq.ackTxBuffer(0);
    try std.testing.expect(mq.txBuffer(0) == null);
}

test "round robin skips empty slots and keeps unacked packets" {
    const std = @import("std");
    var mq = MessageQueue{ .registered_nodes = 3 };

    try mq.pushMessage(0, .{ .to = 1 }, PRIORITY_LOW);
    try mq.pushMessage(2, .{ .to = 3 }, PRIORITY_LOW);

    try std.testing.expectEqual(@as(?usize, 0), mq.roundRobinTx());
    try std.testing.expectEqual(@as(?usize, 2), mq.roundRobinTx());
    try std.testing.expectEqual(@as(?usize, 0), mq.roundRobinTx());

    mq.ackTxBuffer(0);
    mq.ackTxBuffer(2);
    try std.testing.expectEqual(@as(?usize, null), mq.roundRobinTx());
    try std.testing.expect(mq.allEmpty());
}

test {
    _ = @import("message_queue/tree.zig");
    _ = @import("message_queue/priority_queue.zig");
}
