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
    mq_idk: usize,
    to: u16,
};

pub const MessageQueueMap = struct {
    mq_idx: usize,
    addr: u16,
};

pub const ForwardingTable = struct {
    output_map: [MAX_NEIGHBORS]MessageQueueMap = undefined,
    num_registered_output_map: usize = 0,

    forwarding_table: [MAX_NEIGHBORS]ForwardingEntry = undefined,
    num_forwards: usize = 0,
};
