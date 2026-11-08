//! C ABI bindings for running a single Yggdrasil node from a host process

const std = @import("std");
const ygg = @import("yggdrasil");

const Yggdrasil = ygg.Yggdrasil;
const NetworkPacket = ygg.NetworkPacket;
const YggdrasilError = ygg.YggdrasilError;

pub const WriteCallback = *const fn (ptr: [*]const u8, len: usize) callconv(.c) c_int;
pub const PacketCallback = *const fn (origin: u16, from: u16, dest: u16, broadcast: bool, ptr: [*]const u8, len: usize) callconv(.c) void;
pub const NeighborLostCallback = *const fn (addr: u16) callconv(.c) void;

var node: Yggdrasil = undefined;
var initialized = false;
var rx_buffer: [256]u8 = undefined;

var write_cb: ?WriteCallback = null;
var packet_cb: ?PacketCallback = null;
var lost_cb: ?NeighborLostCallback = null;

var now_ms: u32 = 0;
var staged: []const u8 = &.{};

fn clock() u32 {
    return now_ms;
}

fn readBytes(buf: []u8) YggdrasilError![]u8 {
    const n = @min(buf.len, staged.len);
    @memcpy(buf[0..n], staged[0..n]);
    staged = staged[n..];
    return buf[0..n];
}

fn writeBytes(buf: []u8) YggdrasilError!void {
    const cb = write_cb orelse return error.WriteFailed;
    if (cb(buf.ptr, buf.len) != 0) return error.WriteFailed;
}

fn onPacket(packet: NetworkPacket) void {
    const cb = packet_cb orelse return;
    const body = packet.body();
    cb(packet.origin, packet.from, packet.dest, packet.broadcast, body.ptr, body.len);
}

fn onNeighborLost(addr: u16) void {
    if (lost_cb) |cb| cb(addr);
}

export fn ygg_init(
    address: u16,
    is_root: bool,
    write: ?WriteCallback,
    packet: ?PacketCallback,
    lost: ?NeighborLostCallback,
) void {
    write_cb = write;
    packet_cb = packet;
    lost_cb = lost;
    node = .{
        .read_bytes_fn = readBytes,
        .write_bytes_fn = writeBytes,
        .result_cb = onPacket,
        .address = address,
        .clock = clock,
        .neighbor_lost_cb = onNeighborLost,
        .retransmit_timeout_ms = 4_000,
        .retransmit_jitter_ms = 1_500,
        .root_timeout_ms = 450_000,
        .is_root = is_root,
    };
    node.buffer = &rx_buffer;
    initialized = true;
}

export fn ygg_set_time(ms: u32) void {
    now_ms = ms;
}

export fn ygg_feed(ptr: [*]const u8, len: usize) c_int {
    if (!initialized) return -1;
    staged = ptr[0..len];
    while (staged.len > 0) node.readStream() catch {};
    return 0;
}

export fn ygg_request_write() c_int {
    if (!initialized) return -1;
    const wrote = node.requestWrite() catch return -2;
    return @intFromBool(wrote);
}

export fn ygg_say_hello() c_int {
    if (!initialized) return -1;
    node.sayHello() catch return -2;
    return 0;
}

export fn ygg_announce_root() void {
    if (initialized) node.announceRoot();
}

export fn ygg_announce_topology() void {
    if (initialized) node.announceTopology();
}

export fn ygg_root_address() i32 {
    if (!initialized) return -1;
    return node.rootAddress() orelse -1;
}

export fn ygg_send(dest: u16, ptr: [*]const u8, len: usize, priority: u8) c_int {
    if (!initialized) return -1;
    node.send(dest, ptr[0..len], priority) catch |e| return switch (e) {
        error.NoRoute => 1,
        error.PayloadTooLarge => 2,
        else => 3,
    };
    return 0;
}

export fn ygg_neighbor_count() u32 {
    if (!initialized) return 0;
    return @intCast(node.forwarding_table.num_registered_output_map);
}

export fn ygg_neighbor(i: u32) i32 {
    if (!initialized or i >= node.forwarding_table.num_registered_output_map) return -1;
    return node.forwarding_table.output_map[i].addr;
}
