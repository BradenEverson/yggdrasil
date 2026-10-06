//! Priority queue for some type, uses a lil ol int as the priority level

const tree = @import("tree.zig");

pub const PQError = tree.FixedSizeBinaryTreeError;

pub fn PriorityQueue(comptime T: type, comptime MAX_ELEMS: usize) type {
    const Tree = tree.FixedSizeBinaryTree(T, MAX_ELEMS);
    _ = Tree;

    return struct {};
}
