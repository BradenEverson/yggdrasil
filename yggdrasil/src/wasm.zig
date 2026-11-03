const std = @import("std");
const ygg = @import("yggdrasil");

const Yggdrasil = ygg.Yggdrasil;
const NetworkPacket = ygg.NetworkPacket;
const MessageQueue = ygg.MessageQueue;
const YggdrasilError = ygg.YggdrasilError;
const Writer = std.Io.Writer;

extern "env" fn js_write(node: u32, ptr: [*]const u8, len: usize) void;
extern "env" fn js_read(node: u32, ptr: [*]u8, cap: usize) usize;
extern "env" fn js_packet(node: u32, ptr: [*]const u8, len: usize) void;
extern "env" fn js_panic(ptr: [*]const u8, len: usize) void;

pub const panic = std.debug.FullPanic(wasmPanic);

fn wasmPanic(msg: []const u8, _: ?usize) noreturn {
    js_panic(msg.ptr, msg.len);
    @trap();
}

const allocator = std.heap.wasm_allocator;

pub const MAX_NODES: usize = 64;

const RX_BUFFER_SIZE: usize = 256;

const Stats = struct {
    bytes_written: u64 = 0,
    bytes_read: u64 = 0,
    write_calls: u64 = 0,
    read_calls: u64 = 0,
    packets_received: u64 = 0,
    packets_enqueued: u64 = 0,
    enqueue_failures: u64 = 0,
    shim_transmits: u64 = 0,
    raw_transmits: u64 = 0,
};

const Node = struct {
    ygg: Yggdrasil,
    rx_buffer: [RX_BUFFER_SIZE]u8,
    stats: Stats,
};

var nodes: [MAX_NODES]?*Node = @splat(null);
var current: u32 = 0;

var json_buffer: [1 << 20]u8 = undefined;
var json_len: usize = 0;
var cb_buffer: [4096]u8 = undefined;

fn readBytes(buf: []u8) YggdrasilError![]u8 {
    const node = nodes[current].?;
    const n = @min(js_read(current, buf.ptr, buf.len), buf.len);
    node.stats.read_calls += 1;
    node.stats.bytes_read += n;
    return buf[0..n];
}

fn writeBytes(buf: []u8) YggdrasilError!void {
    const node = nodes[current].?;
    node.stats.write_calls += 1;
    node.stats.bytes_written += buf.len;
    js_write(current, buf.ptr, buf.len);
}

fn packetReceived(packet: NetworkPacket) void {
    const node = nodes[current].?;
    node.stats.packets_received += 1;

    var w: Writer = .fixed(&cb_buffer);
    writePacket(&w, &packet) catch return;
    const out = w.buffered();
    js_packet(current, out.ptr, out.len);
}

export fn ygg_alloc(len: usize) ?[*]u8 {
    const mem = allocator.alloc(u8, len) catch return null;
    return mem.ptr;
}

export fn ygg_free(ptr: [*]u8, len: usize) void {
    allocator.free(ptr[0..len]);
}

export fn ygg_max_nodes() u32 {
    return MAX_NODES;
}

export fn ygg_max_payload() u32 {
    return @typeInfo(@FieldType(NetworkPacket, "payload")).array.len;
}

export fn ygg_max_neighbors() u32 {
    return MessageQueue.MAX_NEIGHBORS;
}

export fn ygg_max_queue_length() u32 {
    return MessageQueue.MAX_MESSAGE_QUEUE_LENGTH;
}

export fn ygg_node_create(address: u16) i32 {
    for (&nodes, 0..) |*slot, i| {
        if (slot.* != null) continue;

        const node = allocator.create(Node) catch return -1;
        node.stats = .{};
        node.ygg = .{
            .read_bytes_fn = readBytes,
            .write_bytes_fn = writeBytes,
            .result_cb = packetReceived,
            .address = address,
        };
        node.ygg.buffer = &node.rx_buffer;
        slot.* = node;
        return @intCast(i);
    }
    return -1;
}

export fn ygg_node_destroy(h: u32) void {
    if (h >= MAX_NODES) return;
    if (nodes[h]) |node| {
        allocator.destroy(node);
        nodes[h] = null;
    }
}

export fn ygg_node_set_address(h: u32, address: u16) void {
    const node = get(h) orelse return;
    node.ygg.address = address;
}

export fn ygg_node_reset_parser(h: u32) void {
    const node = get(h) orelse return;
    node.ygg.state = .awaiting_header;
    node.ygg.cursor = 0;
}

export fn ygg_read_stream(h: u32) i32 {
    const node = enter(h) orelse return -1;
    node.ygg.readStream() catch return 1;
    return 0;
}

export fn ygg_request_write(h: u32) i32 {
    const node = enter(h) orelse return -1;
    node.ygg.requestWrite() catch return 1;
    return 0;
}

export fn ygg_enqueue(
    h: u32,
    slot: u32,
    to: u16,
    flags: u8,
    payload_ptr: [*]const u8,
    payload_len: usize,
    priority: u8,
) i32 {
    const node = enter(h) orelse return -1;
    if (slot >= MessageQueue.MAX_NEIGHBORS) return 2;

    const packet = buildPacket(node, to, flags, payload_ptr[0..payload_len]) orelse return 3;

    node.ygg.outgoing_packets.pushMessage(slot, packet, priority) catch {
        node.stats.enqueue_failures += 1;
        return 1;
    };

    const mq = &node.ygg.outgoing_packets;
    if (slot + 1 > mq.registered_nodes) mq.registered_nodes = slot + 1;

    node.stats.packets_enqueued += 1;
    return 0;
}

export fn ygg_shim_transmit_next(h: u32) i32 {
    const node = enter(h) orelse return -1;
    var packet = node.ygg.outgoing_packets.roundRobinPop() orelse return 0;

    var buf: [300]u8 = undefined;
    const bytes = packet.toBuffer(&buf);
    node.ygg.write_bytes_fn(bytes) catch return -2;
    node.stats.shim_transmits += 1;
    return 1;
}

export fn ygg_transmit_raw(
    h: u32,
    to: u16,
    flags: u8,
    payload_ptr: [*]const u8,
    payload_len: usize,
) i32 {
    const node = enter(h) orelse return -1;
    var packet = buildPacket(node, to, flags, payload_ptr[0..payload_len]) orelse return 3;

    var buf: [300]u8 = undefined;
    const bytes = packet.toBuffer(&buf);
    node.ygg.write_bytes_fn(bytes) catch return -2;
    node.stats.raw_transmits += 1;
    return 0;
}

const FLAG_ACK: u8 = 1 << 7;
const FLAG_BROADCAST: u8 = 1 << 6;
const FLAG_NACK: u8 = 1 << 5;
const FLAG_SN: u8 = 1 << 4;
const FLAG_NESN: u8 = 1 << 3;

fn buildPacket(node: *Node, to: u16, flags: u8, payload: []const u8) ?NetworkPacket {
    var packet: NetworkPacket = .{
        .from = node.ygg.address,
        .to = to,
        .ack = flags & FLAG_ACK != 0,
        .broadcast = flags & FLAG_BROADCAST != 0,
        .nack = flags & FLAG_NACK != 0,
        .sn = flags & FLAG_SN != 0,
        .nesn = flags & FLAG_NESN != 0,
    };
    if (payload.len > packet.payload.len) return null;
    packet.len = @intCast(payload.len);
    @memcpy(packet.payload[0..payload.len], payload);
    return packet;
}

fn get(h: u32) ?*Node {
    if (h >= MAX_NODES) return null;
    return nodes[h];
}

fn enter(h: u32) ?*Node {
    const node = get(h) orelse return null;
    current = h;
    return node;
}

export fn ygg_json_ptr() [*]const u8 {
    return &json_buffer;
}

export fn ygg_json_len() usize {
    return json_len;
}

export fn ygg_node_snapshot(h: u32) usize {
    const node = get(h) orelse return 0;
    var w: Writer = .fixed(&json_buffer);
    writeSnapshot(&w, node) catch {
        json_len = 0;
        return 0;
    };
    json_len = w.buffered().len;
    return json_len;
}

fn writeSnapshot(w: *Writer, node: *Node) Writer.Error!void {
    const y = &node.ygg;

    try w.print("{{\"address\":{d},\"stats\":", .{y.address});
    try writeValue(w, node.stats);

    try w.print(",\"parser\":{{\"state\":\"{s}\",\"cursor\":{d},\"buffer\":", .{
        @tagName(y.state),
        y.cursor,
    });
    try writeHex(w, y.packet_buffer[0..@min(y.cursor, y.packet_buffer.len)]);
    try w.writeAll(",\"building\":");
    try writePacket(w, &y.building_packet);
    try w.writeAll("}");

    const mq = &y.outgoing_packets;
    try w.print(",\"mq\":{{\"registered_nodes\":{d},\"cursor\":{d},\"slots\":[", .{
        mq.registered_nodes,
        mq.cursor,
    });
    var first = true;
    for (&mq.slots, 0..) |*pq, i| {
        const size = pq.tree.size;
        if (size == 0 and i >= mq.registered_nodes) continue;
        if (!first) try w.writeAll(",");
        first = false;

        try w.print("{{\"index\":{d},\"size\":{d},\"entries\":[", .{ i, size });
        for (pq.tree.ar[0..@min(size, pq.tree.ar.len)], 0..) |*entry, j| {
            if (j != 0) try w.writeAll(",");
            try w.print("{{\"priority\":{d},\"packet\":", .{entry.priority});
            try writePacket(w, &entry.val);
            try w.writeAll("}");
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]}");

    const ft = &y.forwarding_table;
    try w.writeAll(",\"forwarding\":{\"output_map\":");
    try writeList(w, ft.output_map[0..@min(ft.num_registered_output_map, ft.output_map.len)]);
    try w.writeAll(",\"forwards\":");
    try writeList(w, ft.forwarding_table[0..@min(ft.num_forwards, ft.forwarding_table.len)]);
    try w.writeAll("}");

    try w.writeAll("}");
}

fn writePacket(w: *Writer, p: *const NetworkPacket) Writer.Error!void {
    try w.print(
        "{{\"from\":{d},\"to\":{d},\"ack\":{},\"broadcast\":{},\"nack\":{},\"sn\":{},\"nesn\":{},\"len\":{d},\"crc\":",
        .{ p.from, p.to, p.ack, p.broadcast, p.nack, p.sn, p.nesn, p.len },
    );
    try writeValue(w, p.crc);
    try w.writeAll(",\"payload\":");
    try writeHex(w, p.payload[0..@min(p.len, p.payload.len)]);
    try w.writeAll("}");
}

fn writeList(w: *Writer, items: anytype) Writer.Error!void {
    try w.writeAll("[");
    for (items, 0..) |item, i| {
        if (i != 0) try w.writeAll(",");
        try writeValue(w, item);
    }
    try w.writeAll("]");
}

fn writeHex(w: *Writer, bytes: []const u8) Writer.Error!void {
    try w.writeAll("\"");
    for (bytes) |b| try w.print("{x:0>2}", .{b});
    try w.writeAll("\"");
}

fn writeValue(w: *Writer, v: anytype) Writer.Error!void {
    const T = @TypeOf(v);
    switch (@typeInfo(T)) {
        .int, .comptime_int, .float, .comptime_float => try w.print("{d}", .{v}),
        .bool => try w.writeAll(if (v) "true" else "false"),
        .@"enum" => try w.print("\"{s}\"", .{@tagName(v)}),
        .optional => if (v) |x| try writeValue(w, x) else try w.writeAll("null"),
        .@"struct" => |s| {
            try w.writeAll("{");
            inline for (s.field_names, 0..) |name, i| {
                if (i != 0) try w.writeAll(",");
                try w.print("\"{s}\":", .{name});
                try writeValue(w, @field(v, name));
            }
            try w.writeAll("}");
        },
        .array => |a| {
            if (a.child == u8) {
                try writeHex(w, &v);
            } else {
                try writeList(w, &v);
            }
        },
        else => try w.writeAll("null"),
    }
}
