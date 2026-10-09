//! Routing Implementation, Network Topology graph and forwarding table
//! defintions

pub const MAX_NEIGHBORS: usize = 255;

pub const Node = struct {
    address: u16,
    connections: [MAX_NEIGHBORS]usize = undefined,
    num_connections: usize = 0,
};

pub const SlotmapEntry = struct {
    key: usize,
    node: Node,
};
