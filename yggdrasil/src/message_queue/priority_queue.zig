//! Priority queue for some type, uses a lil ol int as the priority level

const std = @import("std");
const tree = @import("tree.zig");

pub const PQError = tree.FixedSizeBinaryTreeError;

pub fn PriorityQueue(comptime T: type, comptime MAX_ELEMS: usize) type {
    const Entry = struct {
        priority: u8,
        val: T,
    };

    const Tree = tree.FixedSizeBinaryTree(Entry, MAX_ELEMS);

    return struct {
        tree: Tree = .{},

        const Heap = @This();

        pub fn minHeapify(mh: *Heap, i: usize) void {
            if (i >= (mh.tree.size / 2))
                return;

            var smallest = i;

            if (mh.tree.leftExists(i)) {
                const l = mh.tree.left(i);
                if (l.val.priority < mh.tree.ar[i].priority) {
                    smallest = l.id;
                }
            }

            if (mh.tree.rightExists(i)) {
                const r = mh.tree.right(i);
                if (r.val.priority < mh.tree.ar[smallest].priority) {
                    smallest = r.id;
                }
            }

            if (smallest != i) {
                const tmp = mh.tree.ar[smallest];
                mh.tree.ar[smallest] = mh.tree.ar[i];
                mh.tree.ar[i] = tmp;

                mh.minHeapify(smallest);
            }
        }

        pub fn push(mh: *Heap, elem: T, priority: u8) PQError!void {
            try mh.tree.add(.{ .priority = priority, .val = elem });

            var i = mh.tree.size - 1;
            while (i > 0) {
                const parent = (i - 1) / 2;
                if (mh.tree.ar[parent].priority <= mh.tree.ar[i].priority) break;
                std.mem.swap(Entry, &mh.tree.ar[parent], &mh.tree.ar[i]);
                i = parent;
            }
        }
        pub fn pop(mh: *Heap) ?T {
            if (mh.tree.size == 0) return null;

            const res = mh.tree.ar[0];
            mh.tree.size -= 1;
            mh.tree.ar[0] = mh.tree.ar[mh.tree.size];
            mh.minHeapify(0);

            return res.val;
        }
    };
}

test "Basic priority queue" {
    const StringPriorityQueue = PriorityQueue([]const u8, 10);

    var pq = StringPriorityQueue{};
    try pq.push("lower", 1);
    try pq.push("lowest", 2);
    try pq.push("high", 0);

    try std.testing.expectEqualSlices(u8, "high", pq.pop().?);
    try std.testing.expectEqualSlices(u8, "lower", pq.pop().?);
    try std.testing.expectEqualSlices(u8, "lowest", pq.pop().?);
}
