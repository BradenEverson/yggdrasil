const std = @import("std");
const Allocator = std.mem.Allocator;

pub const FixedSizeBinaryTreeError = error{
    TreeFull,
};

pub fn FixedSizeBinaryTree(comptime T: type, comptime N: usize) type {
    return struct {
        ar: [N]T = undefined,
        size: usize = 0,
        initial_size: usize = 4,

        const Tree = @This();

        pub const Entry = struct {
            id: usize,
            val: T,
        };

        pub fn add(tree: *Tree, item: T) FixedSizeBinaryTreeError!void {
            if (tree.size == tree.ar.len) {
                return error.TreeFull;
            }

            tree.ar[tree.size] = item;
            tree.size += 1;
        }

        pub fn getRoot(tree: *Tree) Entry {
            return .{ .id = 0, .val = tree.ar[0] };
        }

        pub fn left(tree: *Tree, root: usize) Entry {
            const idx = 2 * root + 1;
            return .{ .id = idx, .val = tree.ar[idx] };
        }

        pub fn leftExists(tree: *const Tree, root: usize) bool {
            return (2 * root + 1) < tree.size;
        }

        pub fn right(tree: *Tree, root: usize) Entry {
            const idx = 2 * root + 2;
            return .{ .id = idx, .val = tree.ar[idx] };
        }

        pub fn rightExists(tree: *const Tree, root: usize) bool {
            return (2 * root + 2) < tree.size;
        }

        pub fn parent(tree: *Tree, node: usize) Entry {
            const idx = node / 2;
            return .{ .id = idx, .val = tree.ar[idx] };
        }

        pub fn get(tree: *Tree, node: usize) Entry {
            return .{ .id = node, .val = tree.ar[node] };
        }
    };
}

test "Construction and stuff" {
    var tree = FixedSizeBinaryTree(usize, 7){};

    try tree.add(16);

    try tree.add(14);
    try tree.add(10);

    try tree.add(8);
    try tree.add(7);
    try tree.add(9);
    try tree.add(3);

    const root = tree.getRoot();

    try std.testing.expectEqual(16, root.val);

    const left = tree.left(root.id);
    const right = tree.right(root.id);

    try std.testing.expectEqual(14, left.val);
    try std.testing.expectEqual(10, right.val);

    const left_left = tree.left(left.id);
    const left_right = tree.right(left.id);
    const right_left = tree.left(right.id);
    const right_right = tree.right(right.id);

    try std.testing.expectEqual(8, left_left.val);
    try std.testing.expectEqual(7, left_right.val);
    try std.testing.expectEqual(9, right_left.val);
    try std.testing.expectEqual(3, right_right.val);

    try std.testing.expectError(FixedSizeBinaryTreeError.TreeFull, tree.add(10));
}
