//! Routing Implementation, Network Topology graph and forwarding table
//! defintions

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
    mq_idk: usize = 0,
    to: u16 = 0,
};

pub const MessageQueueMap = struct {
    mq_idx: usize = 0,
    addr: u16 = 0,
    sn: bool = false,
    nesn: bool = false,
    ack_pending: bool = false,
};

pub const ForwardingTable = struct {
    output_map: [MAX_NEIGHBORS]MessageQueueMap = @splat(.{}),
    num_registered_output_map: usize = 0,

    forwarding_table: [MAX_NEIGHBORS]ForwardingEntry = @splat(.{}),
    num_forwards: usize = 0,

    pub const Error = error{TooManyNeighbors};

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
};
