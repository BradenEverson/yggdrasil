//! Routing Implementation, Network Topology graph and forwarding table
//! defintions

const std = @import("std");

pub const MAX_NEIGHBORS = @import("message_queue.zig").MAX_NEIGHBORS;

pub const Node = struct {
    address: u16,
    connections: [MAX_NEIGHBORS]usize = undefined,
    num_connections: usize = 0,

    pub fn connect(self: *Node, connection: usize) void {
        self.connections[self.num_connections] = connection;
        self.num_connections += 1;
    }
};

pub const SlotmapEntry = struct {
    key: usize,
    node: *Node,
};

pub const TopologyGraph = struct {
    slotmap: [MAX_NEIGHBORS]Node = undefined,
    num_registered: usize = 0,

    /// Initializes the topology graph with our address
    pub fn init(me: usize) TopologyGraph {
        var graph = TopologyGraph{};
        graph.slotmap[graph.num_registered] = .{ .address = me };
        graph.num_registered += 1;
        return graph;
    }

    pub fn insert(graph: *TopologyGraph, addr: usize) void {
        graph.slotmap[graph.num_registered] = .{ .address = addr };
        graph.num_registered += 1;
    }

    pub fn get(graph: *TopologyGraph, addr: usize) ?SlotmapEntry {
        for (0..graph.num_registered) |i| {
            if (graph.slotmap[i].address == addr)
                return .{ .key = i, .node = &graph.slotmap[i] };
        }

        return null;
    }

    pub fn connect(
        _: *TopologyGraph,
        a: SlotmapEntry,
        b: SlotmapEntry,
    ) void {
        a.node.connect(b.key);
        b.node.connect(a.key);
    }
};

pub const ForwardingEntry = struct {
    mq_idx: usize = 0,
    dest: u16 = 0,
    hops: u8 = 1,
};

pub const Route = struct {
    neighbor: *MessageQueueMap,
    hops: u8,
};

pub const MessageQueueMap = struct {
    mq_idx: usize = 0,
    addr: u16 = 0,
    sn: bool = false,
    nesn: bool = false,
    ack_pending: bool = false,
    sent: bool = false,
    retries: u8 = 0,
    retransmit_at: u32 = 0,
};

pub const ForwardingTable = struct {
    output_map: [MAX_NEIGHBORS]MessageQueueMap = @splat(.{}),
    num_registered_output_map: usize = 0,

    forwarding_table: [MAX_NEIGHBORS]ForwardingEntry = @splat(.{}),
    num_forwards: usize = 0,

    pub const Error = error{ TooManyNeighbors, TooManyRoutes };

    pub fn registerNeighbor(ft: *ForwardingTable, addr: u16, mq_idx: usize) Error!*MessageQueueMap {
        if (ft.neighborByAddr(addr)) |existing| {
            existing.mq_idx = mq_idx;
            return existing;
        }

        if (ft.num_registered_output_map >= MAX_NEIGHBORS)
            return error.TooManyNeighbors;

        const entry = &ft.output_map[ft.num_registered_output_map];
        entry.* = .{ .addr = addr, .mq_idx = mq_idx };
        ft.num_registered_output_map += 1;
        return entry;
    }

    pub fn neighborByAddr(ft: *ForwardingTable, addr: u16) ?*MessageQueueMap {
        for (ft.output_map[0..ft.num_registered_output_map]) |*entry| {
            if (entry.addr == addr) return entry;
        }
        return null;
    }

    pub fn neighborBySlot(ft: *ForwardingTable, mq_idx: usize) ?*MessageQueueMap {
        for (ft.output_map[0..ft.num_registered_output_map]) |*entry| {
            if (entry.mq_idx == mq_idx) return entry;
        }
        return null;
    }

    pub fn removeNeighbor(ft: *ForwardingTable, addr: u16) void {
        for (ft.output_map[0..ft.num_registered_output_map], 0..) |entry, i| {
            if (entry.addr != addr) continue;

            var r = ft.num_forwards;
            while (r > 0) {
                r -= 1;
                if (ft.forwarding_table[r].mq_idx == entry.mq_idx) {
                    ft.num_forwards -= 1;
                    ft.forwarding_table[r] = ft.forwarding_table[ft.num_forwards];
                }
            }

            ft.num_registered_output_map -= 1;
            ft.output_map[i] = ft.output_map[ft.num_registered_output_map];
            return;
        }
    }

    pub fn freeSlot(ft: *ForwardingTable) ?usize {
        for (0..MAX_NEIGHBORS) |slot| {
            if (ft.neighborBySlot(slot) == null) return slot;
        }
        return null;
    }

    pub fn setRoute(ft: *ForwardingTable, dest: u16, mq_idx: usize, hops: u8) Error!void {
        const clamped = @max(hops, 1);

        for (ft.forwarding_table[0..ft.num_forwards]) |*entry| {
            if (entry.dest == dest) {
                entry.mq_idx = mq_idx;
                entry.hops = clamped;
                return;
            }
        }

        if (ft.num_forwards >= MAX_NEIGHBORS)
            return error.TooManyRoutes;

        ft.forwarding_table[ft.num_forwards] = .{ .dest = dest, .mq_idx = mq_idx, .hops = clamped };
        ft.num_forwards += 1;
    }

    pub fn removeRoute(ft: *ForwardingTable, dest: u16) void {
        for (ft.forwarding_table[0..ft.num_forwards], 0..) |entry, i| {
            if (entry.dest == dest) {
                ft.num_forwards -= 1;
                ft.forwarding_table[i] = ft.forwarding_table[ft.num_forwards];
                return;
            }
        }
    }

    pub fn route(ft: *ForwardingTable, dest: u16) ?Route {
        if (ft.neighborByAddr(dest)) |neighbor|
            return .{ .neighbor = neighbor, .hops = 1 };

        for (ft.forwarding_table[0..ft.num_forwards]) |entry| {
            if (entry.dest == dest) {
                const neighbor = ft.neighborBySlot(entry.mq_idx) orelse return null;
                return .{ .neighbor = neighbor, .hops = entry.hops };
            }
        }

        return null;
    }

    pub fn nextHop(ft: *ForwardingTable, dest: u16) ?*MessageQueueMap {
        const found = ft.route(dest) orelse return null;
        return found.neighbor;
    }
};

test "next hop prefers direct neighbors, then forwarding entries" {
    var ft = ForwardingTable{};

    _ = try ft.registerNeighbor(10, 0);
    _ = try ft.registerNeighbor(20, 1);

    try std.testing.expectEqual(@as(?usize, 2), ft.freeSlot());

    try ft.setRoute(30, 1, 3);
    try ft.setRoute(10, 1, 2);

    try std.testing.expectEqual(@as(u16, 10), ft.nextHop(10).?.addr);
    try std.testing.expectEqual(@as(u16, 20), ft.nextHop(30).?.addr);
    try std.testing.expectEqual(@as(u8, 3), ft.route(30).?.hops);
    try std.testing.expect(ft.nextHop(40) == null);

    try ft.setRoute(30, 0, 0);
    try std.testing.expectEqual(@as(u16, 10), ft.nextHop(30).?.addr);
    try std.testing.expectEqual(@as(u8, 1), ft.route(30).?.hops);
    try std.testing.expectEqual(@as(u8, 1), ft.route(10).?.hops);

    ft.removeRoute(30);
    try std.testing.expect(ft.nextHop(30) == null);
}

test "removing a neighbor drops routes through it" {
    var ft = ForwardingTable{};

    _ = try ft.registerNeighbor(10, 0);
    _ = try ft.registerNeighbor(20, 1);
    try ft.setRoute(30, 0, 2);
    try ft.setRoute(40, 1, 2);

    ft.removeNeighbor(10);

    try std.testing.expect(ft.neighborByAddr(10) == null);
    try std.testing.expect(ft.nextHop(30) == null);
    try std.testing.expectEqual(@as(u16, 20), ft.nextHop(40).?.addr);
    try std.testing.expectEqual(@as(?usize, 0), ft.freeSlot());
}
