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

pub const PRIORITY_LOW: usize = 10;
pub const PRIORITY_HIGH: usize = 0;

slots: [MAX_NEIGHBORS]PriorityQueue(NetworkPacket, MAX_MESSAGE_QUEUE_LENGTH) = undefined,
registered_nodes: usize = 0,

test {
    _ = @import("message_queue/tree.zig");
    _ = @import("message_queue/priority_queue.zig");
}
