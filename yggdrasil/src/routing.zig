//! Routing Implementation, Network Topology graph and forwarding table
//! defintions

const std = @import("std");

pub const MAX_NEIGHBORS = @import("message_queue.zig").MAX_NEIGHBORS;

pub const LinkState = struct {
    addr: u16 = 0,
    seq: u16 = 0,
    neighbors: [MAX_NEIGHBORS]u16 = undefined,
    num_neighbors: usize = 0,
    heard_at: u32 = 0,
    flood_pending: bool = false,
    flood_at: u32 = 0,

    pub fn links(ls: *const LinkState) []const u16 {
        return ls.neighbors[0..ls.num_neighbors];
    }

    pub fn lists(ls: *const LinkState, addr: u16) bool {
        return contains(ls.links(), addr);
    }
};

pub const Path = struct {
    dest: u16,
    first_hop: u16,
    cost: u8,
};

fn contains(addrs: []const u16, addr: u16) bool {
    for (addrs) |a| {
        if (a == addr) return true;
    }
    return false;
}

pub fn seqNewer(a: u16, b: u16) bool {
    return @as(i16, @bitCast(a -% b)) > 0;
}

pub const TopologyGraph = struct {
    nodes: [MAX_NEIGHBORS]LinkState = @splat(.{}),
    num_nodes: usize = 0,

    pub const MAX_VERTICES: usize = 2 * MAX_NEIGHBORS + 1;

    pub const Error = error{TooManyNodes};

    pub fn all(graph: *TopologyGraph) []LinkState {
        return graph.nodes[0..graph.num_nodes];
    }

    pub fn get(graph: *TopologyGraph, addr: u16) ?*LinkState {
        for (graph.all()) |*ls| {
            if (ls.addr == addr) return ls;
        }
        return null;
    }

    fn getConst(graph: *const TopologyGraph, addr: u16) ?*const LinkState {
        for (graph.nodes[0..graph.num_nodes]) |*ls| {
            if (ls.addr == addr) return ls;
        }
        return null;
    }

    pub fn update(graph: *TopologyGraph, addr: u16, seq: u16, neighbors: []const u16, now: u32) Error!?*LinkState {
        const entry = if (graph.get(addr)) |existing| blk: {
            if (!seqNewer(seq, existing.seq))
                return null;
            break :blk existing;
        } else blk: {
            if (graph.num_nodes >= MAX_NEIGHBORS)
                return error.TooManyNodes;
            const fresh = &graph.nodes[graph.num_nodes];
            graph.num_nodes += 1;
            fresh.* = .{ .addr = addr };
            break :blk fresh;
        };

        const n = @min(neighbors.len, MAX_NEIGHBORS);
        @memcpy(entry.neighbors[0..n], neighbors[0..n]);
        entry.num_neighbors = n;
        entry.seq = seq;
        entry.heard_at = now;
        return entry;
    }

    pub fn remove(graph: *TopologyGraph, addr: u16) void {
        for (graph.all(), 0..) |ls, i| {
            if (ls.addr != addr) continue;
            graph.num_nodes -= 1;
            graph.nodes[i] = graph.nodes[graph.num_nodes];
            return;
        }
    }

    fn linked(graph: *const TopologyGraph, self_addr: u16, own: []const u16, u: u16, v: u16) bool {
        if (u == self_addr) return contains(own, v);
        if (v == self_addr) return contains(own, u);

        const lu = graph.getConst(u);
        const lv = graph.getConst(v);
        const uv = if (lu) |ls| ls.lists(v) else false;
        const vu = if (lv) |ls| ls.lists(u) else false;

        if (lu != null and lv != null)
            return uv and vu;
        return uv or vu;
    }

    pub fn shortestPaths(graph: *const TopologyGraph, self_addr: u16, own: []const u16, out: []Path) usize {
        const INF = std.math.maxInt(u16);

        var addrs: [MAX_VERTICES]u16 = undefined;
        var num: usize = 0;

        const add = struct {
            fn f(list: *[MAX_VERTICES]u16, len: *usize, addr: u16) void {
                if (len.* >= MAX_VERTICES or contains(list[0..len.*], addr)) return;
                list[len.*] = addr;
                len.* += 1;
            }
        }.f;

        add(&addrs, &num, self_addr);
        for (own) |addr| add(&addrs, &num, addr);
        for (graph.nodes[0..graph.num_nodes]) |*ls| {
            add(&addrs, &num, ls.addr);
            for (ls.links()) |addr| add(&addrs, &num, addr);
        }

        var dist: [MAX_VERTICES]u16 = @splat(INF);
        var first: [MAX_VERTICES]u16 = undefined;
        var done: [MAX_VERTICES]bool = @splat(false);
        dist[0] = 0;

        while (true) {
            var best: ?usize = null;
            for (0..num) |i| {
                if (done[i] or dist[i] == INF) continue;
                if (best == null or dist[i] < dist[best.?]) best = i;
            }
            const u = best orelse break;
            done[u] = true;

            for (0..num) |w| {
                if (done[w] or dist[u] + 1 >= dist[w]) continue;
                if (!graph.linked(self_addr, own, addrs[u], addrs[w])) continue;

                dist[w] = dist[u] + 1;
                first[w] = if (u == 0) addrs[w] else first[u];
            }
        }

        var n: usize = 0;
        for (1..num) |i| {
            if (dist[i] == INF or n >= out.len) continue;
            out[n] = .{ .dest = addrs[i], .first_hop = first[i], .cost = @intCast(@min(dist[i], std.math.maxInt(u8))) };
            n += 1;
        }
        return n;
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

    heard_at: u32 = 0,
    sched_known: bool = false,
    period_ms: u32 = 0,
    next_window: u32 = 0,
    synced_at: u32 = 0,
    hops: u8 = 0xFF,
    tx_at: ?u32 = null,
    announce_pending: bool = false,
    hello_pending: bool = false,
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

    pub fn removeRoutesExcept(ft: *ForwardingTable, keep: ?u16) void {
        var i = ft.num_forwards;
        while (i > 0) {
            i -= 1;
            if (keep != null and ft.forwarding_table[i].dest == keep.?) continue;
            ft.num_forwards -= 1;
            ft.forwarding_table[i] = ft.forwarding_table[ft.num_forwards];
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

fn pathTo(paths: []const Path, dest: u16) ?Path {
    for (paths) |p| {
        if (p.dest == dest) return p;
    }
    return null;
}

test "dijkstra finds shortest paths over advertised links" {
    var graph = TopologyGraph{};
    _ = try graph.update(2, 1, &.{ 1, 3, 5 }, 0);
    _ = try graph.update(3, 1, &.{ 2, 4 }, 0);
    _ = try graph.update(5, 1, &.{ 2, 4 }, 0);
    _ = try graph.update(4, 1, &.{ 3, 5 }, 0);

    var paths: [TopologyGraph.MAX_VERTICES]Path = undefined;
    const n = graph.shortestPaths(1, &.{2}, &paths);
    try std.testing.expectEqual(@as(usize, 4), n);

    try std.testing.expectEqual(Path{ .dest = 2, .first_hop = 2, .cost = 1 }, pathTo(paths[0..n], 2).?);
    try std.testing.expectEqual(Path{ .dest = 3, .first_hop = 2, .cost = 2 }, pathTo(paths[0..n], 3).?);
    try std.testing.expectEqual(Path{ .dest = 4, .first_hop = 2, .cost = 3 }, pathTo(paths[0..n], 4).?);
}

test "links need both ends once both have advertised" {
    var graph = TopologyGraph{};
    _ = try graph.update(2, 1, &.{ 1, 3 }, 0);
    var paths: [TopologyGraph.MAX_VERTICES]Path = undefined;
    try std.testing.expect(pathTo(paths[0..graph.shortestPaths(1, &.{2}, &paths)], 3) != null);

    _ = try graph.update(3, 1, &.{}, 0);
    try std.testing.expect(pathTo(paths[0..graph.shortestPaths(1, &.{2}, &paths)], 3) == null);
}

test "stale advertisements are ignored" {
    var graph = TopologyGraph{};
    try std.testing.expect((try graph.update(2, 5, &.{1}, 0)) != null);
    try std.testing.expect((try graph.update(2, 5, &.{ 1, 3 }, 0)) == null);
    try std.testing.expect((try graph.update(2, 4, &.{ 1, 3 }, 0)) == null);
    try std.testing.expectEqual(@as(usize, 1), graph.get(2).?.num_neighbors);

    try std.testing.expect((try graph.update(2, 0, &.{ 1, 3 }, 0)) == null);
    try std.testing.expect((try graph.update(2, 6, &.{ 1, 3 }, 0)) != null);
    try std.testing.expectEqual(@as(usize, 2), graph.get(2).?.num_neighbors);

    graph.remove(2);
    try std.testing.expect(graph.get(2) == null);
}
