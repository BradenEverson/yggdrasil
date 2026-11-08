//! Root protocol implementation

const std = @import("std");

pub const NetworkPacket = @import("network_packet.zig");
pub const AppPacket = @import("app_packet.zig");
pub const MessageQueue = @import("message_queue.zig");

pub const routing = @import("routing.zig");
pub const link_layer = @import("link_layer.zig");
pub const ForwardingTable = routing.ForwardingTable;

/// Errors that are common to most APIs and
/// communication methods
pub const YggdrasilError = error{ ReadFailed, WriteFailed };
const LARGEST_PACKET_SIZE: usize = 240;

/// Scratch space for serializing an outgoing packet: header + max payload + crc
const TX_BUFFER_SIZE: usize = 256;

comptime {
    if (1 + AppPacket.TopologyInfo.HEADER_LEN + routing.MAX_NEIGHBORS * 2 > NetworkPacket.MAX_PAYLOAD_SIZE)
        @compileError("max_neighbors is too large for a full neighbor list to fit in one topology_info packet");
}

pub const SendError = error{ NoRoute, PayloadTooLarge } || MessageQueue.PushError;
pub const NeighborError = ForwardingTable.Error;

pub const RootRoute = struct {
    addr: u16,
    via: u16,
    hops: u8,
    seq: u16,
    heard_at: u32,
};

/// The states we can be in while reading
/// from the incoming stream
pub const ParseState = enum {
    awaiting_header,

    awaiting_from_msb,
    awaiting_from_lsb,

    awaiting_to_msb,
    awaiting_to_lsb,

    awaiting_origin_msb,
    awaiting_origin_lsb,

    awaiting_dest_msb,
    awaiting_dest_lsb,

    awaiting_ttl,

    awaiting_flags,

    awaiting_len,

    reading_payload,

    awaiting_crc_msb,
    awaiting_crc_lsb,
};

/// The middleware struct between a high level app layer
/// and whatever communication method there is at the
/// physical level (UART, LoRa, whateva)
pub const Yggdrasil = struct {
    /// A non-blocking consume function that reads
    /// whatever bytes are currently available from a
    /// stream source (UART, LoRa, BLE, etc), possibly none
    read_bytes_fn: *const fn (buf: []u8) YggdrasilError![]u8,
    write_bytes_fn: *const fn (buf: []u8) YggdrasilError!void,

    address: u16 = 0,

    outgoing_packets: MessageQueue = .{},
    forwarding_table: ForwardingTable = .{},

    state: ParseState = .awaiting_header,
    cursor: usize = 0,

    buffer: []u8 = undefined,
    packet_buffer: [LARGEST_PACKET_SIZE]u8 = undefined,

    result_cb: *const fn (packet: NetworkPacket) void,

    building_packet: NetworkPacket = .{},

    clock: ?*const fn () u32 = null,
    neighbor_lost_cb: ?*const fn (addr: u16) void = null,
    retransmit_timeout_ms: u32 = 3000,
    retransmit_jitter_ms: u32 = 1000,
    max_retries: u8 = 8,
    rng_state: u32 = 0,

    is_root: bool = false,
    root: ?RootRoute = null,
    root_seq: u16 = 0,
    root_timeout_ms: u32 = 90_000,
    announce_jitter_ms: u32 = 2_000,
    hop_slack: u8 = 2,
    pending_announce: ?NetworkPacket = null,
    announce_at: u32 = 0,

    topology_flooding: bool = true,
    topology: routing.TopologyGraph = .{},
    topology_seq: u16 = 0,
    topology_timeout_ms: u32 = 0,
    own_flood_pending: bool = false,
    own_flood_at: u32 = 0,

    /// scheduling mechanism to wrap around all neighbors' message queues
    pub fn requestWrite(ygg: *Yggdrasil) YggdrasilError!bool {
        const mq = &ygg.outgoing_packets;
        const ft = &ygg.forwarding_table;
        const now = ygg.currentTime();

        ygg.dropUnresponsiveNeighbors(now);
        ygg.expireRoot(now);
        ygg.expireTopology(now);

        for (ft.output_map[0..ft.num_registered_output_map]) |*neighbor| {
            if (!neighbor.ack_pending)
                continue;

            if (mq.txBuffer(neighbor.mq_idx) != null and ygg.retransmitDue(neighbor, now))
                continue;

            var ack = NetworkPacket{
                .from = ygg.address,
                .to = neighbor.addr,
                .origin = ygg.address,
                .dest = neighbor.addr,
                .sn = neighbor.sn,
                .nesn = neighbor.nesn,
            };
            neighbor.ack_pending = false;
            try ygg.writePacket(&ack);
            return true;
        }

        if (ygg.pending_announce) |*announce| {
            if (ygg.clock == null or reached(now, ygg.announce_at)) {
                var packet = announce.*;
                ygg.pending_announce = null;
                try ygg.writePacket(&packet);
                return true;
            }
        }

        if (ygg.nextFlood(now)) |flood| {
            var packet = flood;
            try ygg.writePacket(&packet);
            return true;
        }

        const slot = mq.roundRobinTxWhere(Schedule{ .ygg = ygg, .now = now }, Schedule.ready) orelse return false;
        const packet = mq.txBuffer(slot).?;

        const neighbor = if (packet.broadcast) null else ft.neighborBySlot(slot);
        if (neighbor) |n| {
            packet.from = ygg.address;
            packet.to = n.addr;
            packet.sn = n.sn;
            packet.nesn = n.nesn;
            n.ack_pending = false;

            if (n.sent)
                n.retries +|= 1;
            n.sent = true;
            n.retransmit_at = now +% ygg.retransmit_timeout_ms +% ygg.random(ygg.retransmit_jitter_ms);
        }

        try ygg.writePacket(packet);

        if (neighbor == null)
            mq.ackTxBuffer(slot);

        return true;
    }

    const Schedule = struct {
        ygg: *Yggdrasil,
        now: u32,

        fn ready(sched: Schedule, slot: usize) bool {
            const neighbor = sched.ygg.forwarding_table.neighborBySlot(slot) orelse return true;
            return sched.ygg.retransmitDue(neighbor, sched.now);
        }
    };

    fn currentTime(ygg: *const Yggdrasil) u32 {
        const clock = ygg.clock orelse return 0;
        return clock();
    }

    fn retransmitDue(ygg: *const Yggdrasil, neighbor: *const routing.MessageQueueMap, at: u32) bool {
        if (ygg.clock == null or !neighbor.sent)
            return true;

        return reached(at, neighbor.retransmit_at);
    }

    fn reached(at: u32, deadline: u32) bool {
        return @as(i32, @bitCast(at -% deadline)) >= 0;
    }

    fn random(ygg: *Yggdrasil, max: u32) u32 {
        if (max == 0)
            return 0;

        if (ygg.rng_state == 0)
            ygg.rng_state = (@as(u32, ygg.address) *% 2654435761) | 1;

        var x = ygg.rng_state;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        ygg.rng_state = x;

        return x % (max +| 1);
    }

    fn dropUnresponsiveNeighbors(ygg: *Yggdrasil, at: u32) void {
        if (ygg.clock == null)
            return;

        const ft = &ygg.forwarding_table;
        var i = ft.num_registered_output_map;
        while (i > 0) {
            i -= 1;
            const neighbor = &ft.output_map[i];
            if (neighbor.sent and neighbor.retries >= ygg.max_retries and ygg.retransmitDue(neighbor, at))
                ygg.dropNeighbor(neighbor.addr);
        }
    }

    pub fn dropNeighbor(ygg: *Yggdrasil, addr: u16) void {
        const neighbor = ygg.forwarding_table.neighborByAddr(addr) orelse return;

        ygg.outgoing_packets.clearSlot(neighbor.mq_idx);
        ygg.forwarding_table.removeNeighbor(addr);

        if (ygg.root) |current| {
            if (current.via == addr)
                ygg.root = null;
        }

        ygg.neighborsChanged(false);

        if (ygg.neighbor_lost_cb) |cb|
            cb(addr);
    }

    fn writePacket(ygg: *Yggdrasil, packet: *NetworkPacket) YggdrasilError!void {
        var buf: [TX_BUFFER_SIZE]u8 = undefined;
        packet.crc = null;
        try ygg.write_bytes_fn(packet.toBuffer(&buf));
    }

    pub fn registerNeighbor(ygg: *Yggdrasil, addr: u16, slot: usize) NeighborError!*routing.MessageQueueMap {
        const known = ygg.forwarding_table.neighborByAddr(addr) != null;
        const neighbor = try ygg.forwarding_table.registerNeighbor(addr, slot);

        const mq = &ygg.outgoing_packets;
        if (slot + 1 > mq.registered_nodes)
            mq.registered_nodes = slot + 1;

        if (!known)
            ygg.neighborsChanged(true);

        return neighbor;
    }

    pub fn announceTopology(ygg: *Yggdrasil) void {
        if (!ygg.topology_flooding)
            return;

        ygg.topology_seq +%= 1;
        ygg.own_flood_pending = true;
        ygg.own_flood_at = ygg.currentTime();
    }

    fn neighborsChanged(ygg: *Yggdrasil, added: bool) void {
        if (!ygg.topology_flooding)
            return;

        const now = ygg.currentTime();
        ygg.topology_seq +%= 1;
        ygg.own_flood_pending = true;
        ygg.own_flood_at = now +% ygg.random(ygg.announce_jitter_ms);

        if (added)
            ygg.syncTopology();

        ygg.recomputeRoutes();
    }

    fn syncTopology(ygg: *Yggdrasil) void {
        if (!ygg.topology_flooding)
            return;

        const now = ygg.currentTime();
        for (ygg.topology.all()) |*ls| {
            if (ls.flood_pending) continue;
            ls.flood_pending = true;
            ls.flood_at = now +% ygg.random(ygg.announce_jitter_ms);
        }
    }

    fn nextFlood(ygg: *Yggdrasil, now: u32) ?NetworkPacket {
        if (!ygg.topology_flooding)
            return null;

        if (ygg.own_flood_pending and (ygg.clock == null or reached(now, ygg.own_flood_at))) {
            ygg.own_flood_pending = false;

            const ft = &ygg.forwarding_table;
            var own: [routing.MAX_NEIGHBORS]u16 = undefined;
            for (ft.output_map[0..ft.num_registered_output_map], 0..) |n, i| own[i] = n.addr;

            return ygg.topologyPacket(ygg.address, ygg.topology_seq, own[0..ft.num_registered_output_map]);
        }

        for (ygg.topology.all()) |*ls| {
            if (!ls.flood_pending or !(ygg.clock == null or reached(now, ls.flood_at)))
                continue;

            ls.flood_pending = false;
            return ygg.topologyPacket(ls.addr, ls.seq, ls.links());
        }

        return null;
    }

    fn topologyPacket(ygg: *const Yggdrasil, origin: u16, seq: u16, neighbors: []const u16) NetworkPacket {
        var packet = NetworkPacket{
            .from = ygg.address,
            .to = NetworkPacket.BROADCAST_ADDR,
            .origin = origin,
            .dest = NetworkPacket.BROADCAST_ADDR,
            .broadcast = true,
        };
        packet.payload[0] = @backingInt(AppPacket.Opcode.topology_info);
        const info = AppPacket.TopologyInfo.write(origin, seq, neighbors, packet.payload[1..]) catch unreachable;
        packet.len = @intCast(1 + info.len);
        return packet;
    }

    fn handleTopologyInfo(ygg: *Yggdrasil, from: u16, payload: []const u8) void {
        if (!ygg.topology_flooding)
            return;

        const info = AppPacket.TopologyInfo.parse(payload) orelse return;
        _ = ygg.learnNeighbor(from) catch {};

        if (info.origin == ygg.address) {
            if (routing.seqNewer(info.seq, ygg.topology_seq)) {
                ygg.topology_seq = info.seq;
                ygg.announceTopology();
            }
            return;
        }

        var neighbors: [routing.MAX_NEIGHBORS]u16 = undefined;
        const n = @min(info.count(), neighbors.len);
        for (0..n) |i| neighbors[i] = info.neighbor(i);

        const now = ygg.currentTime();
        const entry = (ygg.topology.update(info.origin, info.seq, neighbors[0..n], now) catch return) orelse return;
        entry.flood_pending = true;
        entry.flood_at = now +% ygg.random(ygg.announce_jitter_ms);

        ygg.recomputeRoutes();
    }

    fn expireTopology(ygg: *Yggdrasil, at: u32) void {
        if (ygg.clock == null or ygg.topology_timeout_ms == 0)
            return;

        var changed = false;
        var i = ygg.topology.num_nodes;
        while (i > 0) {
            i -= 1;
            const ls = ygg.topology.nodes[i];
            if (at -% ls.heard_at < ygg.topology_timeout_ms) continue;
            ygg.topology.remove(ls.addr);
            changed = true;
        }

        if (changed)
            ygg.recomputeRoutes();
    }

    pub fn recomputeRoutes(ygg: *Yggdrasil) void {
        if (!ygg.topology_flooding)
            return;

        const ft = &ygg.forwarding_table;
        const root_addr: ?u16 = if (ygg.root) |r| r.addr else null;
        ft.removeRoutesExcept(root_addr);

        var own: [routing.MAX_NEIGHBORS]u16 = undefined;
        for (ft.output_map[0..ft.num_registered_output_map], 0..) |n, i| own[i] = n.addr;

        var paths: [routing.TopologyGraph.MAX_VERTICES]routing.Path = undefined;
        const n = ygg.topology.shortestPaths(ygg.address, own[0..ft.num_registered_output_map], &paths);

        for (paths[0..n]) |path| {
            if (path.cost < 2 or root_addr == path.dest) continue;
            const via = ft.neighborByAddr(path.first_hop) orelse continue;
            ft.setRoute(path.dest, via.mq_idx, path.cost) catch break;
        }
    }

    pub fn learnNeighbor(ygg: *Yggdrasil, addr: u16) NeighborError!*routing.MessageQueueMap {
        const ft = &ygg.forwarding_table;

        if (ft.neighborByAddr(addr)) |existing|
            return existing;

        const slot = ft.freeSlot() orelse return error.TooManyNeighbors;
        return ygg.registerNeighbor(addr, slot);
    }

    pub fn send(ygg: *Yggdrasil, dest: u16, payload: []const u8, priority: u8) SendError!void {
        const found = ygg.forwarding_table.route(dest) orelse return error.NoRoute;

        var packet = NetworkPacket{
            .from = ygg.address,
            .to = found.neighbor.addr,
            .origin = ygg.address,
            .dest = dest,
            .ttl = found.hops +| ygg.hop_slack,
        };
        try packet.setPayload(payload);

        try ygg.outgoing_packets.pushMessage(found.neighbor.mq_idx, packet, priority);
    }

    pub fn rootAddress(ygg: *const Yggdrasil) ?u16 {
        if (ygg.is_root)
            return ygg.address;

        const current = ygg.root orelse return null;
        return current.addr;
    }

    pub fn sendToRoot(ygg: *Yggdrasil, payload: []const u8, priority: u8) SendError!void {
        const current = ygg.root orelse return error.NoRoute;
        try ygg.send(current.addr, payload, priority);
    }

    pub fn sendAppToRoot(ygg: *Yggdrasil, app: AppPacket, priority: u8) SendError!void {
        const current = ygg.root orelse return error.NoRoute;
        try ygg.sendApp(current.addr, app, priority);
    }

    pub fn announceRoot(ygg: *Yggdrasil) void {
        if (!ygg.is_root)
            return;

        ygg.root_seq +%= 1;
        ygg.queueAnnouncement(.{ .root = ygg.address, .seq = ygg.root_seq, .hops = 0 }, ygg.currentTime());
    }

    fn queueAnnouncement(ygg: *Yggdrasil, ann: AppPacket.RootAnnouncement, at: u32) void {
        var packet = NetworkPacket{
            .from = ygg.address,
            .to = NetworkPacket.BROADCAST_ADDR,
            .origin = ygg.address,
            .dest = NetworkPacket.BROADCAST_ADDR,
            .broadcast = true,
            .len = 1 + AppPacket.RootAnnouncement.LEN,
        };
        packet.payload[0] = @backingInt(AppPacket.Opcode.im_a_root);
        ann.write(packet.payload[1..][0..AppPacket.RootAnnouncement.LEN]);

        ygg.pending_announce = packet;
        ygg.announce_at = at;
    }

    fn answerHello(ygg: *Yggdrasil) void {
        if (ygg.pending_announce != null)
            return;

        const ann: AppPacket.RootAnnouncement = if (ygg.is_root)
            .{ .root = ygg.address, .seq = ygg.root_seq, .hops = 0 }
        else if (ygg.root) |current|
            .{ .root = current.addr, .seq = current.seq, .hops = current.hops }
        else
            return;

        ygg.queueAnnouncement(ann, ygg.currentTime() +% ygg.random(ygg.announce_jitter_ms));
    }

    fn handleRootAnnouncement(ygg: *Yggdrasil, from: u16, payload: []const u8) void {
        if (ygg.is_root)
            return;

        const ann = AppPacket.RootAnnouncement.parse(payload) orelse return;
        if (ann.root == ygg.address)
            return;

        const neighbor = ygg.learnNeighbor(from) catch return;
        const hops = ann.hops +| 1;
        const now = ygg.currentTime();

        if (ygg.root) |*current| {
            if (current.addr == ann.root) {
                const newer = @as(i16, @bitCast(ann.seq -% current.seq)) > 0;
                const shorter = ann.seq == current.seq and hops < current.hops;

                if (!newer and !shorter) {
                    if (ann.seq == current.seq and from == current.via)
                        current.heard_at = now;
                    return;
                }
            } else {
                if (hops >= current.hops)
                    return;

                ygg.forwarding_table.removeRoute(current.addr);
            }
        }

        ygg.forwarding_table.setRoute(ann.root, neighbor.mq_idx, hops) catch return;
        ygg.root = .{
            .addr = ann.root,
            .via = from,
            .hops = hops,
            .seq = ann.seq,
            .heard_at = now,
        };

        ygg.queueAnnouncement(
            .{ .root = ann.root, .seq = ann.seq, .hops = hops },
            now +% ygg.random(ygg.announce_jitter_ms),
        );

        ygg.recomputeRoutes();
    }

    fn refreshDirectRoot(ygg: *Yggdrasil, from: u16) void {
        if (ygg.root) |*current| {
            if (current.addr == from and current.via == from)
                current.heard_at = ygg.currentTime();
        }
    }

    fn expireRoot(ygg: *Yggdrasil, at: u32) void {
        if (ygg.clock == null or ygg.root_timeout_ms == 0)
            return;

        const current = ygg.root orelse return;
        if (at -% current.heard_at < ygg.root_timeout_ms)
            return;

        ygg.forwarding_table.removeRoute(current.addr);
        ygg.root = null;
        ygg.recomputeRoutes();
    }

    pub fn sendApp(ygg: *Yggdrasil, dest: u16, app: AppPacket, priority: u8) SendError!void {
        var buf: [NetworkPacket.MAX_PAYLOAD_SIZE]u8 = undefined;
        const bytes = app.write(&buf) catch return error.PayloadTooLarge;
        try ygg.send(dest, bytes, priority);
    }

    pub fn sayHello(ygg: *Yggdrasil) YggdrasilError!void {
        const ft = &ygg.forwarding_table;
        for (ft.output_map[0..ft.num_registered_output_map]) |*neighbor|
            resetLink(neighbor);

        var packet = NetworkPacket{
            .from = ygg.address,
            .to = NetworkPacket.BROADCAST_ADDR,
            .origin = ygg.address,
            .dest = NetworkPacket.BROADCAST_ADDR,
            .broadcast = true,
            .len = 1,
        };
        packet.payload[0] = @backingInt(AppPacket.Opcode.hello);

        try ygg.writePacket(&packet);
    }

    fn resetLink(neighbor: *routing.MessageQueueMap) void {
        neighbor.sn = false;
        neighbor.nesn = false;
        neighbor.ack_pending = false;
        neighbor.sent = false;
        neighbor.retries = 0;
    }

    fn replyHello(ygg: *Yggdrasil, addr: u16) (NeighborError || SendError)!void {
        const known = ygg.forwarding_table.neighborByAddr(addr) != null;
        const neighbor = try ygg.learnNeighbor(addr);

        if (known) {
            resetLink(neighbor);
            ygg.syncTopology();
        }

        var reply = NetworkPacket{
            .from = ygg.address,
            .to = addr,
            .origin = ygg.address,
            .dest = addr,
            .ack = true,
            .len = 1,
        };
        reply.payload[0] = @backingInt(AppPacket.Opcode.hello);

        try ygg.outgoing_packets.pushMessage(neighbor.mq_idx, reply, MessageQueue.PRIORITY_HIGH);
    }

    fn forward(ygg: *Yggdrasil, packet: NetworkPacket) void {
        if (packet.ttl <= 1)
            return;

        const hop = ygg.forwarding_table.nextHop(packet.dest) orelse return;

        if (hop.addr == packet.from)
            return;

        var forwarded = packet;
        forwarded.from = ygg.address;
        forwarded.to = hop.addr;
        forwarded.ttl = packet.ttl - 1;
        forwarded.crc = null;

        ygg.outgoing_packets.pushMessage(hop.mq_idx, forwarded, MessageQueue.PRIORITY_LOW) catch {};
    }

    fn handleBroadcast(ygg: *Yggdrasil, packet: NetworkPacket) void {
        if (packet.from == ygg.address)
            return;

        if (AppPacket.parse(packet.body())) |app| {
            switch (app.op) {
                .hello => {
                    ygg.replyHello(packet.from) catch {};
                    ygg.answerHello();
                },
                .im_a_root => ygg.handleRootAnnouncement(packet.from, app.payload),
                .topology_info => ygg.handleTopologyInfo(packet.from, app.payload),
                else => {},
            }
        }

        ygg.result_cb(packet);
    }

    /// Handles network level packets that are relevant to routing tables, forwarding,
    /// etc. Passes through most (maybe all?) messages to the app level callback as well
    pub fn handle_network_packet(ygg: *Yggdrasil, packet: NetworkPacket) void {
        ygg.refreshDirectRoot(packet.from);

        if (packet.broadcast) {
            ygg.handleBroadcast(packet);
            return;
        }

        if (packet.to != ygg.address)
            return;

        if (packet.from != ygg.address)
            _ = ygg.learnNeighbor(packet.from) catch {};

        if (ygg.forwarding_table.neighborByAddr(packet.from)) |neighbor| {
            if (link_layer.isLinkOnly(&packet)) {
                link_layer.processAck(ygg, neighbor, packet.nesn);
                return;
            }

            if (!link_layer.linkLayerProcess(ygg, neighbor, packet.sn, packet.nesn))
                return;
        }

        if (packet.dest == ygg.address) {
            ygg.result_cb(packet);
        } else {
            ygg.forward(packet);
        }
    }

    /// Superloop that will constantly poll the provided read function and feed it to
    /// a state machine for parsing out Yggdrasil packets. Performs a quick verification
    /// of the CRC, and if successful passes the message to the callback :D
    pub fn readStream(ygg: *Yggdrasil) YggdrasilError!void {
        const bytes = try ygg.read_bytes_fn(ygg.buffer);

        for (bytes) |byte| {
            if (ygg.readByte(byte)) |packet| {
                if (NetworkPacket.CRC.validateCRC(
                    ygg.packet_buffer[0 .. ygg.building_packet.len + NetworkPacket.HEADER_LEN],
                    ygg.building_packet.crc.?,
                )) {
                    ygg.handle_network_packet(packet);
                } else {
                    // TODO!!!!!!!!!!!!
                    // Call error callback!
                    //
                    // The application from here can
                    // choose to send a nack, shouldn't
                    // be our decision here
                }
            }
        }
    }

    pub fn readByte(ygg: *Yggdrasil, byte: u8) ?NetworkPacket {
        ygg.packet_buffer[ygg.cursor] = byte;
        ygg.cursor += 1;

        switch (ygg.state) {
            .awaiting_header => {
                if (byte == NetworkPacket.HEADER) {
                    ygg.state = .awaiting_from_msb;
                } else {
                    ygg.cursor = 0;
                }
            },

            .awaiting_from_msb => {
                ygg.building_packet.from = @as(u16, byte) << 8;
                ygg.state = .awaiting_from_lsb;
            },
            .awaiting_from_lsb => {
                ygg.building_packet.from |= byte;
                ygg.state = .awaiting_to_msb;
            },

            .awaiting_to_msb => {
                ygg.building_packet.to = @as(u16, byte) << 8;
                ygg.state = .awaiting_to_lsb;
            },
            .awaiting_to_lsb => {
                ygg.building_packet.to |= byte;
                ygg.state = .awaiting_origin_msb;
            },

            .awaiting_origin_msb => {
                ygg.building_packet.origin = @as(u16, byte) << 8;
                ygg.state = .awaiting_origin_lsb;
            },
            .awaiting_origin_lsb => {
                ygg.building_packet.origin |= byte;
                ygg.state = .awaiting_dest_msb;
            },

            .awaiting_dest_msb => {
                ygg.building_packet.dest = @as(u16, byte) << 8;
                ygg.state = .awaiting_dest_lsb;
            },
            .awaiting_dest_lsb => {
                ygg.building_packet.dest |= byte;
                ygg.state = .awaiting_ttl;
            },

            .awaiting_ttl => {
                ygg.building_packet.ttl = byte;
                ygg.state = .awaiting_flags;
            },

            .awaiting_flags => {
                ygg.building_packet.parseFlags(byte);
                ygg.state = .awaiting_len;
            },

            .awaiting_len => {
                ygg.building_packet.len = byte;

                if (byte > NetworkPacket.MAX_PAYLOAD_SIZE) {
                    ygg.state = .awaiting_header;
                    ygg.cursor = 0;
                } else if (byte == 0) {
                    ygg.state = .awaiting_crc_msb;
                } else {
                    ygg.state = .reading_payload;
                }
            },
            .reading_payload => {
                ygg.building_packet.payload[ygg.cursor - NetworkPacket.HEADER_LEN - 1] = byte;
                if (ygg.cursor == ygg.building_packet.len + NetworkPacket.HEADER_LEN) {
                    ygg.state = .awaiting_crc_msb;
                }
            },

            .awaiting_crc_msb => {
                ygg.building_packet.crc = @as(u16, byte) << 8;
                ygg.state = .awaiting_crc_lsb;
            },
            .awaiting_crc_lsb => {
                ygg.building_packet.crc.? |= byte;

                ygg.state = .awaiting_header;
                ygg.cursor = 0;
                return ygg.building_packet;
            },
        }

        return null;
    }
};

test "Simple packet parsing" {
    var buffer: [64]u8 = undefined;

    const Runtime = struct {
        var seen: bool = false;

        fn packetEvent(packet: NetworkPacket) void {
            _ = packet;
            seen = true;
        }

        fn read(buf: []u8) YggdrasilError![]u8 {
            var nop = NetworkPacket{};

            const packet = nop.toBuffer(buf);

            return packet;
        }

        fn write(buf: []u8) YggdrasilError!void {
            _ = buf;
        }
    };

    var ygg = Yggdrasil{
        .read_bytes_fn = Runtime.read,
        .write_bytes_fn = Runtime.write,
        .result_cb = Runtime.packetEvent,
        .buffer = &buffer,
    };

    try ygg.readStream();
    try std.testing.expect(Runtime.seen);
}

const TestNet = struct {
    var wire: [TX_BUFFER_SIZE]u8 = undefined;
    var wire_len: usize = 0;
    var delivered: ?NetworkPacket = null;

    fn read(buf: []u8) YggdrasilError![]u8 {
        return buf[0..0];
    }

    fn write(buf: []u8) YggdrasilError!void {
        @memcpy(wire[0..buf.len], buf);
        wire_len = buf.len;
    }

    fn cb(packet: NetworkPacket) void {
        delivered = packet;
    }

    fn node(addr: u16) Yggdrasil {
        return .{
            .read_bytes_fn = read,
            .write_bytes_fn = write,
            .result_cb = cb,
            .address = addr,
            .topology_flooding = false,
        };
    }

    fn hear(ygg: *Yggdrasil) !void {
        for (wire[0..wire_len]) |byte| {
            if (ygg.readByte(byte)) |packet| {
                try std.testing.expect(NetworkPacket.CRC.validateCRC(
                    ygg.packet_buffer[0 .. packet.len + NetworkPacket.HEADER_LEN],
                    packet.crc.?,
                ));
                ygg.handle_network_packet(packet);
            }
        }
    }

    fn transmit(from: *Yggdrasil, listeners: []const *Yggdrasil) !void {
        try std.testing.expect(try from.requestWrite());
        for (listeners) |listener| try hear(listener);
    }
};

test "hello handshake registers neighbors on both sides" {
    var a = TestNet.node(1);
    var b = TestNet.node(2);

    try a.sayHello();
    try TestNet.hear(&b);

    try std.testing.expect(TestNet.delivered.?.broadcast);
    try std.testing.expect(b.forwarding_table.neighborByAddr(1) != null);
    try std.testing.expect(a.forwarding_table.neighborByAddr(2) == null);

    try TestNet.transmit(&b, &.{&a});

    try std.testing.expect(a.forwarding_table.neighborByAddr(2) != null);
    try std.testing.expect(TestNet.delivered.?.ack);
    try std.testing.expectEqual(AppPacket.Opcode.hello, AppPacket.parse(TestNet.delivered.?.body()).?.op);

    try TestNet.transmit(&a, &.{&b});

    try std.testing.expect(b.outgoing_packets.allEmpty());
    try std.testing.expect(a.outgoing_packets.allEmpty());
    try std.testing.expect(!try a.requestWrite());
    try std.testing.expect(!try b.requestWrite());
}

test "packets are forwarded across hops with origin preserved" {
    var a = TestNet.node(1);
    var b = TestNet.node(2);
    var c = TestNet.node(3);

    try a.sayHello();
    try TestNet.hear(&b);
    try TestNet.transmit(&b, &.{ &a, &c });
    try TestNet.transmit(&a, &.{&b});

    try c.sayHello();
    try TestNet.hear(&b);
    try TestNet.transmit(&b, &.{ &a, &c });
    try TestNet.transmit(&c, &.{&b});

    try std.testing.expect(c.forwarding_table.neighborByAddr(1) == null);

    try a.forwarding_table.setRoute(3, a.forwarding_table.neighborByAddr(2).?.mq_idx, 2);
    try c.forwarding_table.setRoute(1, c.forwarding_table.neighborByAddr(2).?.mq_idx, 2);

    TestNet.delivered = null;

    try a.send(3, "hi", MessageQueue.PRIORITY_LOW);
    try TestNet.transmit(&a, &.{ &b, &c });
    try std.testing.expect(TestNet.delivered == null);

    try TestNet.transmit(&b, &.{&a});
    try std.testing.expect(a.outgoing_packets.allEmpty());

    try TestNet.transmit(&b, &.{ &a, &c });

    const got = TestNet.delivered.?;
    try std.testing.expectEqual(@as(u16, 1), got.origin);
    try std.testing.expectEqual(@as(u16, 3), got.dest);
    try std.testing.expectEqual(@as(u16, 2), got.from);
    try std.testing.expectEqualSlices(u8, "hi", got.body());

    try TestNet.transmit(&c, &.{&b});
    try std.testing.expect(b.outgoing_packets.allEmpty());

    try std.testing.expectError(error.NoRoute, b.send(99, "x", MessageQueue.PRIORITY_LOW));
}

const TestClock = struct {
    var time: u32 = 0;
    var lost: ?u16 = null;

    fn now() u32 {
        return time;
    }

    fn onLost(addr: u16) void {
        lost = addr;
    }

    fn node(addr: u16) Yggdrasil {
        var ygg = TestNet.node(addr);
        ygg.clock = now;
        ygg.neighbor_lost_cb = onLost;
        ygg.retransmit_timeout_ms = 100;
        ygg.retransmit_jitter_ms = 10;
        ygg.max_retries = 2;
        return ygg;
    }
};

test "max size packets fit the radio and parse" {
    var a = TestNet.node(1);
    var b = TestNet.node(2);
    _ = try a.registerNeighbor(2, 0);
    _ = try b.registerNeighbor(1, 0);

    var payload: [NetworkPacket.MAX_PAYLOAD_SIZE]u8 = undefined;
    for (&payload, 0..) |*byte, i| byte.* = @truncate(i);

    try a.send(2, &payload, MessageQueue.PRIORITY_LOW);
    TestNet.delivered = null;
    try TestNet.transmit(&a, &.{&b});

    try std.testing.expectEqual(LARGEST_PACKET_SIZE, TestNet.wire_len);
    try std.testing.expectEqualSlices(u8, &payload, TestNet.delivered.?.body());
    try std.testing.expectError(error.PayloadTooLarge, a.send(2, &(payload ++ [_]u8{0}), MessageQueue.PRIORITY_LOW));
}

test "retransmits wait for the timer and unresponsive neighbors are dropped" {
    TestClock.time = 0;
    TestClock.lost = null;

    var a = TestClock.node(1);
    _ = try a.registerNeighbor(2, 0);
    try a.forwarding_table.setRoute(3, 0, 2);

    try a.send(2, "x", MessageQueue.PRIORITY_LOW);

    try std.testing.expect(try a.requestWrite());
    try std.testing.expect(!try a.requestWrite());

    TestClock.time = 99;
    try std.testing.expect(!try a.requestWrite());

    TestClock.time = 110;
    try std.testing.expect(try a.requestWrite());
    try std.testing.expect(!try a.requestWrite());

    TestClock.time = 220;
    try std.testing.expect(try a.requestWrite());
    try std.testing.expect(TestClock.lost == null);

    TestClock.time = 330;
    try std.testing.expect(!try a.requestWrite());
    try std.testing.expectEqual(@as(?u16, 2), TestClock.lost);
    try std.testing.expect(a.forwarding_table.nextHop(2) == null);
    try std.testing.expect(a.forwarding_table.nextHop(3) == null);
    try std.testing.expect(a.outgoing_packets.allEmpty());
}

test "acked packets stop retransmitting and acks skip the timer" {
    TestClock.time = 0;
    TestClock.lost = null;

    var a = TestClock.node(1);
    var b = TestClock.node(2);
    _ = try a.registerNeighbor(2, 0);
    _ = try b.registerNeighbor(1, 0);

    try a.send(2, "x", MessageQueue.PRIORITY_LOW);
    try TestNet.transmit(&a, &.{});

    try b.send(1, "y", MessageQueue.PRIORITY_LOW);
    try TestNet.transmit(&b, &.{&a});

    try TestNet.transmit(&a, &.{&b});
    try std.testing.expectEqual(NetworkPacket.HEADER_LEN + 2, TestNet.wire_len);
    try std.testing.expect(b.outgoing_packets.allEmpty());
    try std.testing.expect(!a.outgoing_packets.allEmpty());

    TestClock.time = 200;
    TestNet.delivered = null;
    try TestNet.transmit(&a, &.{&b});
    try std.testing.expectEqualSlices(u8, "x", TestNet.delivered.?.body());

    try TestNet.transmit(&b, &.{&a});
    try std.testing.expect(a.outgoing_packets.allEmpty());

    TestClock.time = 1000;
    try std.testing.expect(!try a.requestWrite());
    try std.testing.expect(!try b.requestWrite());
    try std.testing.expect(TestClock.lost == null);
}

fn announcementFrom(ygg: *Yggdrasil, root: u16, seq: u16, hops: u8) void {
    ygg.queueAnnouncement(.{ .root = root, .seq = seq, .hops = hops }, 0);
}

test "root announcements build routes across hops and set ttl from them" {
    var a = TestNet.node(1);
    var b = TestNet.node(2);
    var c = TestNet.node(3);
    a.is_root = true;
    c.hop_slack = 0;

    a.announceRoot();
    try TestNet.transmit(&a, &.{&b});

    try std.testing.expectEqual(@as(?u16, 1), b.rootAddress());
    try std.testing.expectEqual(@as(u8, 1), b.root.?.hops);
    try std.testing.expect(c.rootAddress() == null);

    try TestNet.transmit(&b, &.{ &a, &c });

    try std.testing.expectEqual(@as(?u16, 1), c.rootAddress());
    try std.testing.expectEqual(@as(u8, 2), c.root.?.hops);
    try std.testing.expectEqual(@as(u16, 2), c.root.?.via);
    try std.testing.expect(a.root == null);

    try TestNet.transmit(&c, &.{&b});
    try std.testing.expectEqual(@as(u8, 1), b.root.?.hops);
    try std.testing.expect(b.pending_announce == null);

    TestNet.delivered = null;
    try c.sendToRoot("r", MessageQueue.PRIORITY_LOW);
    try std.testing.expectEqual(@as(u8, 2), c.outgoing_packets.txBuffer(c.forwarding_table.neighborByAddr(2).?.mq_idx).?.ttl);

    try TestNet.transmit(&c, &.{&b});
    try TestNet.transmit(&b, &.{&c});
    try TestNet.transmit(&b, &.{&a});

    const got = TestNet.delivered.?;
    try std.testing.expectEqual(@as(u16, 3), got.origin);
    try std.testing.expectEqual(@as(u16, 1), got.dest);
    try std.testing.expectEqual(@as(u8, 1), got.ttl);
    try std.testing.expectEqualSlices(u8, "r", got.body());
}

const Mesh = struct {
    nodes: []const *Yggdrasil,
    links: []const [2]u16,

    fn hears(mesh: Mesh, a: u16, b: u16) bool {
        for (mesh.links) |l| {
            if ((l[0] == a and l[1] == b) or (l[0] == b and l[1] == a)) return true;
        }
        return false;
    }

    fn broadcast(mesh: Mesh, from: *Yggdrasil) !void {
        for (mesh.nodes) |n| {
            if (n != from and mesh.hears(from.address, n.address)) try TestNet.hear(n);
        }
    }

    fn hello(mesh: Mesh, ygg: *Yggdrasil) !void {
        try ygg.sayHello();
        try mesh.broadcast(ygg);
    }

    fn settle(mesh: Mesh) !void {
        for (0..10_000) |_| {
            var any = false;
            for (mesh.nodes) |n| {
                if (try n.requestWrite()) {
                    any = true;
                    try mesh.broadcast(n);
                }
            }
            if (!any) return;
        }
        return error.NeverSettled;
    }

    fn cut(mesh: Mesh, a: *Yggdrasil, b: *Yggdrasil) void {
        _ = mesh;
        a.dropNeighbor(b.address);
        b.dropNeighbor(a.address);
    }
};

fn meshNode(addr: u16) Yggdrasil {
    var ygg = TestNet.node(addr);
    ygg.topology_flooding = true;
    return ygg;
}

test "link-state flooding gives every node routes across the mesh" {
    var n1 = meshNode(1);
    var n2 = meshNode(2);
    var n3 = meshNode(3);
    var n4 = meshNode(4);
    var mesh = Mesh{
        .nodes = &.{ &n1, &n2, &n3, &n4 },
        .links = &.{ .{ 1, 2 }, .{ 2, 3 }, .{ 3, 4 } },
    };

    for (mesh.nodes) |n| try mesh.hello(n);
    try mesh.settle();

    try std.testing.expectEqual(@as(u16, 2), n1.forwarding_table.route(4).?.neighbor.addr);
    try std.testing.expectEqual(@as(u8, 3), n1.forwarding_table.route(4).?.hops);
    try std.testing.expectEqual(@as(u8, 2), n1.forwarding_table.route(3).?.hops);
    try std.testing.expectEqual(@as(u16, 3), n4.forwarding_table.route(1).?.neighbor.addr);
    try std.testing.expectEqual(@as(u8, 3), n4.forwarding_table.route(1).?.hops);
    try std.testing.expectEqual(@as(u16, 3), n2.forwarding_table.route(4).?.neighbor.addr);
    try std.testing.expectEqual(@as(u16, 2), n3.forwarding_table.route(1).?.neighbor.addr);

    TestNet.delivered = null;
    try n1.send(4, "far", MessageQueue.PRIORITY_LOW);
    try mesh.settle();

    const got = TestNet.delivered.?;
    try std.testing.expectEqual(@as(u16, 1), got.origin);
    try std.testing.expectEqual(@as(u16, 4), got.dest);
    try std.testing.expectEqualSlices(u8, "far", got.body());

    TestNet.delivered = null;
    try n4.send(1, "back", MessageQueue.PRIORITY_LOW);
    try mesh.settle();
    try std.testing.expectEqual(@as(u16, 1), TestNet.delivered.?.dest);
    try std.testing.expectEqualSlices(u8, "back", TestNet.delivered.?.body());
}

test "routes move to the next shortest path when a link breaks" {
    var n1 = meshNode(1);
    var n2 = meshNode(2);
    var n3 = meshNode(3);
    var n4 = meshNode(4);
    var n5 = meshNode(5);
    var mesh = Mesh{
        .nodes = &.{ &n1, &n2, &n3, &n4, &n5 },
        .links = &.{ .{ 1, 2 }, .{ 2, 3 }, .{ 1, 4 }, .{ 4, 5 }, .{ 5, 3 } },
    };

    for (mesh.nodes) |n| try mesh.hello(n);
    try mesh.settle();

    try std.testing.expectEqual(@as(u16, 2), n1.forwarding_table.route(3).?.neighbor.addr);
    try std.testing.expectEqual(@as(u8, 2), n1.forwarding_table.route(3).?.hops);

    mesh.links = &.{ .{ 1, 2 }, .{ 1, 4 }, .{ 4, 5 }, .{ 5, 3 } };
    mesh.cut(&n2, &n3);
    try mesh.settle();

    try std.testing.expectEqual(@as(u16, 4), n1.forwarding_table.route(3).?.neighbor.addr);
    try std.testing.expectEqual(@as(u8, 3), n1.forwarding_table.route(3).?.hops);
    try std.testing.expectEqual(@as(u16, 1), n2.forwarding_table.route(3).?.neighbor.addr);
    try std.testing.expectEqual(@as(u8, 4), n2.forwarding_table.route(3).?.hops);

    TestNet.delivered = null;
    try n2.send(3, "around", MessageQueue.PRIORITY_LOW);
    try mesh.settle();
    try std.testing.expectEqual(@as(u16, 3), TestNet.delivered.?.dest);
    try std.testing.expectEqualSlices(u8, "around", TestNet.delivered.?.body());
}

test "a rebooted node outbids its own stale advertisement" {
    var n1 = meshNode(1);
    var n2 = meshNode(2);
    var n3 = meshNode(3);
    var mesh = Mesh{
        .nodes = &.{ &n1, &n2, &n3 },
        .links = &.{ .{ 1, 2 }, .{ 2, 3 } },
    };

    for (mesh.nodes) |n| try mesh.hello(n);
    for (0..4) |_| {
        n1.announceTopology();
        try mesh.settle();
    }
    const before = n1.topology_seq;
    try std.testing.expectEqual(before, n3.topology.get(1).?.seq);

    n1 = meshNode(1);
    try mesh.hello(&n1);
    try mesh.settle();

    try std.testing.expect(routing.seqNewer(n1.topology_seq, before));
    try std.testing.expectEqual(n1.topology_seq, n3.topology.get(1).?.seq);
    try std.testing.expectEqual(@as(u8, 2), n1.forwarding_table.route(3).?.hops);
    try std.testing.expectEqual(@as(u8, 2), n3.forwarding_table.route(1).?.hops);
}

test "packets are dropped when their hop limit runs out" {
    var b = TestNet.node(2);
    var c = TestNet.node(3);
    c.hop_slack = 0;

    _ = try b.registerNeighbor(1, 0);
    _ = try b.registerNeighbor(3, 1);
    _ = try c.registerNeighbor(2, 0);
    try c.forwarding_table.setRoute(1, 0, 1);

    try c.send(1, "r", MessageQueue.PRIORITY_LOW);
    try TestNet.transmit(&c, &.{&b});

    try TestNet.transmit(&b, &.{&c});
    try std.testing.expect(c.outgoing_packets.allEmpty());
    try std.testing.expect(b.outgoing_packets.allEmpty());
    try std.testing.expect(!try b.requestWrite());
}

test "newer sequence numbers win, shorter paths win within a sequence" {
    var a = TestNet.node(10);
    var b = TestNet.node(20);
    var c = TestNet.node(30);

    announcementFrom(&a, 1, 5, 3);
    try TestNet.transmit(&a, &.{&c});
    try std.testing.expectEqual(@as(u8, 4), c.root.?.hops);
    try std.testing.expectEqual(@as(u16, 10), c.root.?.via);

    announcementFrom(&b, 1, 5, 1);
    try TestNet.transmit(&b, &.{&c});
    try std.testing.expectEqual(@as(u8, 2), c.root.?.hops);
    try std.testing.expectEqual(@as(u16, 20), c.root.?.via);

    announcementFrom(&a, 1, 5, 0);
    try TestNet.transmit(&a, &.{&c});
    try std.testing.expectEqual(@as(u8, 1), c.root.?.hops);
    try std.testing.expectEqual(@as(u16, 10), c.forwarding_table.nextHop(1).?.addr);

    announcementFrom(&b, 1, 4, 0);
    try TestNet.transmit(&b, &.{&c});
    try std.testing.expectEqual(@as(u16, 10), c.root.?.via);

    announcementFrom(&b, 1, 6, 7);
    try TestNet.transmit(&b, &.{&c});
    try std.testing.expectEqual(@as(u16, 20), c.root.?.via);
    try std.testing.expectEqual(@as(u8, 8), c.root.?.hops);
    try std.testing.expectEqual(@as(u8, 8), c.forwarding_table.route(1).?.hops);
}

test "any frame from a direct root keeps it alive" {
    TestClock.time = 0;

    var a = TestClock.node(1);
    var b = TestClock.node(2);
    a.is_root = true;
    b.root_timeout_ms = 1000;

    a.announceRoot();
    try TestNet.transmit(&a, &.{&b});
    try std.testing.expectEqual(@as(?u16, 1), b.rootAddress());

    TestClock.time = 900;
    try a.sayHello();
    try TestNet.hear(&b);

    TestClock.time = 1800;
    _ = try b.requestWrite();
    try std.testing.expectEqual(@as(?u16, 1), b.rootAddress());

    TestClock.time = 1900;
    _ = try b.requestWrite();
    try std.testing.expect(b.rootAddress() == null);
}

test "hello is answered with a root announcement" {
    TestClock.time = 0;

    var a = TestClock.node(1);
    var b = TestClock.node(2);
    var c = TestClock.node(3);
    a.is_root = true;

    a.announceRoot();
    try TestNet.transmit(&a, &.{&b});
    try std.testing.expectEqual(@as(?u16, 1), b.rootAddress());
    b.pending_announce = null;

    try c.sayHello();
    try TestNet.hear(&b);
    try std.testing.expect(b.pending_announce != null);

    TestClock.time = b.announce_at;
    try TestNet.transmit(&b, &.{&c});
    try std.testing.expectEqual(@as(?u16, 1), c.rootAddress());
    try std.testing.expectEqual(@as(u8, 2), c.root.?.hops);
}

test "root routes expire without fresh announcements" {
    TestClock.time = 0;

    var a = TestClock.node(1);
    var b = TestClock.node(2);
    a.is_root = true;
    b.root_timeout_ms = 1000;

    a.announceRoot();
    try TestNet.transmit(&a, &.{&b});
    try std.testing.expectEqual(@as(?u16, 1), b.rootAddress());

    TestClock.time = 999;
    _ = try b.requestWrite();
    try std.testing.expectEqual(@as(?u16, 1), b.rootAddress());

    TestClock.time = 1000;
    _ = try b.requestWrite();
    try std.testing.expect(b.rootAddress() == null);
    try std.testing.expect(b.forwarding_table.forwarding_table[0..b.forwarding_table.num_forwards].len == 0);
    try std.testing.expectError(error.NoRoute, b.sendToRoot("x", MessageQueue.PRIORITY_LOW));
}

test {
    _ = @import("network_packet.zig");
    _ = @import("app_packet.zig");
    _ = @import("routing.zig");
    _ = @import("message_queue.zig");
    _ = @import("link_layer.zig");
}
