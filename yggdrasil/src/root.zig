//! Root protocol implementation

const std = @import("std");

pub const NetworkPacket = @import("network_packet.zig");
pub const AppPacket = @import("app_packet.zig");
pub const MessageQueue = @import("message_queue.zig");

pub const routing = @import("routing.zig");
pub const link_layer = @import("link_layer.zig");
pub const lora = @import("lora.zig");
pub const power = @import("power.zig");
pub const Power = power.Power;
pub const ForwardingTable = routing.ForwardingTable;
pub const Address = NetworkPacket.Address;

/// Errors that are common to most APIs and
/// communication methods
pub const YggdrasilError = error{ ReadFailed, WriteFailed };

/// Scratch space for serializing an outgoing packet
const TX_BUFFER_SIZE: usize = 256;

comptime {
    if (1 + AppPacket.TopologyInfo.HEADER_LEN + routing.MAX_NEIGHBORS > NetworkPacket.MAX_PAYLOAD_SIZE)
        @compileError("max_neighbors is too large for a full neighbor list to fit in one topology_info packet");
}

pub const SendError = error{ NoRoute, PayloadTooLarge } || MessageQueue.PushError;
pub const NeighborError = ForwardingTable.Error || error{AtCapacity};

pub const RootRoute = struct {
    addr: Address,
    via: Address,
    hops: u8,
    seq: u16,
    heard_at: u32,
};

const JoinCandidate = struct {
    ann: AppPacket.RootAnnouncement,
    via: Address,
    hops: u8,
};

/// The middleware struct between a high level app layer
/// and whatever communication method there is at the
/// physical level (UART, LoRa, whateva)
pub const Yggdrasil = struct {
    /// A non-blocking consume function that returns
    /// one whole received frame, or an empty slice
    /// when nothing has arrived
    read_bytes_fn: *const fn (buf: []u8) YggdrasilError![]u8,
    write_bytes_fn: *const fn (buf: []u8) YggdrasilError!void,

    address: Address = 0,

    outgoing_packets: MessageQueue = .{},
    forwarding_table: ForwardingTable = .{},

    buffer: []u8 = undefined,

    result_cb: *const fn (packet: NetworkPacket) void,

    clock: ?*const fn () u32 = null,
    neighbor_lost_cb: ?*const fn (addr: Address) void = null,
    retransmit_timeout_ms: u32 = 3000,
    retransmit_jitter_ms: u32 = 1000,
    max_retries: u8 = 8,
    rng_state: u32 = 0,

    is_root: bool = false,
    max_children: usize = 0,
    root: ?RootRoute = null,
    root_seq: u16 = 0,
    root_timeout_ms: u32 = 90_000,
    announce_jitter_ms: u32 = 2_000,
    hop_slack: u8 = 2,
    pending_announce: ?NetworkPacket = null,
    announce_at: u32 = 0,

    topology_flooding: bool = true,
    merge_readings: bool = true,
    topology: routing.TopologyGraph = .{},
    topology_seq: u16 = 0,
    topology_timeout_ms: u32 = 0,
    own_flood_pending: bool = false,
    own_flood_at: u32 = 0,

    power: ?Power = null,
    topology_reporting: bool = false,
    own_window: u32 = 0,
    own_window_set: bool = false,
    old_window: u32 = 0,
    old_window_until: ?u32 = null,
    awake_until: u32 = 0,
    ack_wait_until: ?u32 = null,
    joining_until: ?u32 = null,
    next_join_at: ?u32 = null,
    hellos_left: u8 = 0,
    next_hello_at: u32 = 0,
    ever_rooted: bool = false,
    next_beacon_at: ?u32 = null,
    join_backoff_ms: u32 = 0,
    lost_root: ?RootRoute = null,
    lost_root_at: u32 = 0,
    join_candidate: ?JoinCandidate = null,
    report_at: ?u32 = null,
    reported_at: u32 = 0,
    reported_once: bool = false,

    /// scheduling mechanism to wrap around all neighbors' message queues
    pub fn requestWrite(ygg: *Yggdrasil) YggdrasilError!bool {
        const mq = &ygg.outgoing_packets;
        const ft = &ygg.forwarding_table;
        const now = ygg.currentTime();

        ygg.dropUnresponsiveNeighbors(now);
        ygg.expireRoot(now);
        ygg.expireTopology(now);

        if (ygg.power != null) {
            ygg.expireNeighbors(now);
            if (try ygg.maintainJoin(now))
                return true;
            ygg.maintainBeacon(now);
            ygg.refill();
            ygg.maintainReport(now);
        }

        if (ygg.ack_wait_until) |until| {
            if (!reached(now, until))
                return false;
            ygg.ack_wait_until = null;
        }

        for (ft.output_map[0..ft.num_registered_output_map]) |*neighbor| {
            if (!neighbor.ack_pending)
                continue;

            if (busy(neighbor, now))
                continue;

            if (mq.txBuffer(neighbor.mq_idx)) |pending| {
                if (ygg.sendable(neighbor, now, frameLen(pending)))
                    continue;
            }

            if (!ygg.reachable(neighbor, now, power.ACK_FRAME))
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
            n.tx_at = null;
            n.retransmit_at = now +% ygg.retransmitDelay(frameLen(packet));
        }

        try ygg.writePacket(packet);

        if (neighbor == null) {
            mq.ackTxBuffer(slot);
        } else {
            ygg.expectAck(frameLen(packet));
        }

        return true;
    }

    fn expectAck(ygg: *Yggdrasil, len: usize) void {
        const p = ygg.power orelse return;
        if (ygg.clock == null)
            return;

        const until = ygg.currentTime() +% p.frameMs(len) +% p.backoffMs();
        ygg.ack_wait_until = until;
        ygg.stayAwake(until);
    }

    fn busy(neighbor: *routing.MessageQueueMap, now: u32) bool {
        const until = neighbor.busy_until orelse return false;
        if (reached(now, until)) {
            neighbor.busy_until = null;
            return false;
        }
        return true;
    }

    const Schedule = struct {
        ygg: *Yggdrasil,
        now: u32,

        fn ready(sched: Schedule, slot: usize) bool {
            const neighbor = sched.ygg.forwarding_table.neighborBySlot(slot) orelse return true;
            const packet = sched.ygg.outgoing_packets.tx_buffers[slot] orelse return false;
            return sched.ygg.sendable(neighbor, sched.now, frameLen(&packet));
        }
    };

    fn frameLen(packet: *const NetworkPacket) usize {
        return packet.frameLen();
    }

    fn retransmitDelay(ygg: *Yggdrasil, len: usize) u32 {
        if (ygg.power) |p|
            return p.lingerMs(len) +% ygg.random(p.backoffMs());
        return ygg.retransmit_timeout_ms +% ygg.random(ygg.retransmit_jitter_ms);
    }

    fn sendable(ygg: *Yggdrasil, neighbor: *routing.MessageQueueMap, now: u32, len: usize) bool {
        if (!ygg.retransmitDue(neighbor, now))
            return false;
        if (ygg.power == null)
            return true;
        return reached(now, ygg.plannedTx(neighbor, now, len)) and ygg.reachable(neighbor, now, len);
    }

    fn alwaysListening(neighbor: *const routing.MessageQueueMap) bool {
        return !neighbor.sched_known or neighbor.period_ms == 0;
    }

    fn lingering(ygg: *const Yggdrasil, neighbor: *const routing.MessageQueueMap, now: u32, len: usize) bool {
        const p = ygg.power orelse return true;
        if (!neighbor.sched_known)
            return false;
        return (now +% p.frameMs(len)) -% neighbor.heard_at < p.lingerMs(power.ACK_FRAME);
    }

    fn guardFor(ygg: *const Yggdrasil, neighbor: *const routing.MessageQueueMap, now: u32, len: usize) u32 {
        const p = ygg.power.?;
        const window = p.windowMs();
        const cap = (window -| p.frameMs(len)) / 2;
        return @min(p.guardMs(now -% neighbor.synced_at), cap);
    }

    fn reachable(ygg: *const Yggdrasil, neighbor: *const routing.MessageQueueMap, now: u32, len: usize) bool {
        const p = ygg.power orelse return true;
        if (alwaysListening(neighbor) or ygg.lingering(neighbor, now, len))
            return true;

        const start = power.windowAt(neighbor.next_window, neighbor.period_ms, now);
        const into = now -% start;
        const g = ygg.guardFor(neighbor, now, len);
        const frame = p.frameMs(len);
        if (frame + 2 * g > p.windowMs())
            return into >= g and into <= g + p.backoffMs();
        return into >= g and into + frame + g <= p.windowMs();
    }

    fn plannedTx(ygg: *Yggdrasil, neighbor: *routing.MessageQueueMap, from_at: u32, len: usize) u32 {
        const p = ygg.power orelse return from_at;

        const from = if (neighbor.busy_until) |t| (if (after(t, from_at)) t else from_at) else from_at;

        if (ygg.lingering(neighbor, from, len)) {
            if (neighbor.tx_at) |t| {
                if (after(t, from) and !after(t, from +% 2 * p.backoffMs()))
                    return t;
            }
            return from;
        }

        if (alwaysListening(neighbor)) {
            if (neighbor.tx_at) |t| {
                if (after(t, from) and !after(t, from +% 2 * p.backoffMs()))
                    return t;
            }
            return ygg.outsideOwnWindow(from);
        }

        var start = power.windowAt(neighbor.next_window, neighbor.period_ms, from);
        const g = ygg.guardFor(neighbor, from, len);
        const usable = @max(p.windowMs() -| (g + p.frameMs(len)), g);
        if (from -% start > usable)
            start +%= neighbor.period_ms;

        const earliest = if (after(start +% g, from)) start +% g else from;
        const latest = start +% usable;

        if (neighbor.tx_at) |t| {
            if (reached(t, start +% g) and reached(latest, t))
                return t;
        }

        const span = if (after(latest, earliest)) @min(p.backoffMs(), latest -% earliest) else 0;
        const t = earliest +% ygg.random(span);
        neighbor.tx_at = t;
        return t;
    }

    fn after(a: u32, b: u32) bool {
        return power.after(a, b);
    }

    fn stayAwake(ygg: *Yggdrasil, until: u32) void {
        if (after(until, ygg.awake_until))
            ygg.awake_until = until;
    }

    fn ownHops(ygg: *const Yggdrasil) u8 {
        if (ygg.is_root)
            return 0;
        const current = ygg.root orelse return NetworkPacket.NO_HOPS;
        return current.hops;
    }

    fn ownWindowStart(ygg: *Yggdrasil, now: u32) u32 {
        const p = ygg.power.?;
        const period = p.periodMs();
        if (!ygg.own_window_set) {
            ygg.own_window = now +% ygg.random(period);
            ygg.own_window_set = true;
        }
        return power.windowAt(ygg.own_window, period, now);
    }

    fn ownWindowOpen(ygg: *Yggdrasil, now: u32) bool {
        const p = ygg.power orelse return true;
        if (!p.sleepy())
            return true;

        const window = p.windowMs();
        if (now -% ygg.ownWindowStart(now) < window)
            return true;

        const until = ygg.old_window_until orelse return false;
        if (reached(now, until)) {
            ygg.old_window_until = null;
            return false;
        }
        return now -% power.windowAt(ygg.old_window, p.periodMs(), now) < window;
    }

    fn stamp(ygg: *Yggdrasil, packet: *NetworkPacket) void {
        packet.hops = ygg.ownHops();
        packet.wake_phase = null;
        packet.period = null;

        const p = ygg.power orelse return;
        if (!p.sleepy())
            return;

        const now = ygg.currentTime();
        const next = ygg.ownWindowStart(now) +% p.periodMs();
        packet.wake_phase = NetworkPacket.wakePhase(next -% now, p.periodMs());
        if (packet.broadcast or carriesPeriod(packet))
            packet.period = p.advertisedPeriod();
    }

    fn carriesPeriod(packet: *const NetworkPacket) bool {
        const app = AppPacket.parse(packet.body()) orelse return false;
        return app.op == .hello or app.op == .im_a_root;
    }

    fn trafficLen(ygg: *Yggdrasil, neighbor: *routing.MessageQueueMap, now: u32) ?usize {
        const p = ygg.power.?;
        if (ygg.outgoing_packets.txBuffer(neighbor.mq_idx)) |packet|
            return frameLen(packet);
        if (neighbor.hello_pending or neighbor.announce_pending)
            return p.frame_budget;
        if (neighbor.ack_pending and ygg.lingering(neighbor, now, power.ACK_FRAME))
            return power.ACK_FRAME;
        return null;
    }

    const Wake = struct {
        now: u32,
        at: u32,

        fn consider(wake: *Wake, t: u32) void {
            if (!after(t, wake.now)) {
                wake.at = wake.now;
            } else if (after(wake.at, t)) {
                wake.at = t;
            }
        }
    };

    pub fn idleFor(ygg: *Yggdrasil) u32 {
        const p = ygg.power orelse return 0;
        if (!p.sleepy())
            return 0;

        const now = ygg.currentTime();
        if (ygg.joining_until != null or after(ygg.awake_until, now))
            return 0;
        ygg.awake_until = now;

        if (ygg.ownWindowOpen(now))
            return 0;

        const period = p.periodMs();
        var wake = Wake{ .now = now, .at = now +% p.max_idle_ms };
        wake.consider(ygg.ownWindowStart(now) +% period);
        if (ygg.old_window_until != null)
            wake.consider(power.windowAt(ygg.old_window, period, now) +% period);

        const ft = &ygg.forwarding_table;
        for (ft.output_map[0..ft.num_registered_output_map]) |*neighbor| {
            const len = ygg.trafficLen(neighbor, now) orelse continue;
            const from = if (neighbor.sent and after(neighbor.retransmit_at, now)) neighbor.retransmit_at else now;
            wake.consider(ygg.plannedTx(neighbor, from, len));
        }

        if (!ygg.is_root and ygg.root == null) {
            if (ygg.next_join_at) |t| wake.consider(t) else wake.consider(now);
        }

        if (ygg.root) |current| {
            if (ygg.root_timeout_ms != 0)
                wake.consider(current.heard_at +% ygg.root_timeout_ms);
            if (ygg.topology_reporting and !ygg.is_root)
                wake.consider(ygg.reportDueAt(p));
        }

        if (ygg.pending_announce != null)
            wake.consider(ygg.announce_at);

        if (ygg.next_beacon_at) |t|
            wake.consider(t);

        if (ygg.topology_flooding and ygg.own_flood_pending)
            wake.consider(ygg.own_flood_at);

        const left = wake.at -% now;
        return if (left <= p.radio_wake_ms) 0 else left - p.radio_wake_ms;
    }

    fn noteFrame(ygg: *Yggdrasil, packet: *const NetworkPacket, now: u32) void {
        const p = ygg.power orelse return;
        if (packet.from == ygg.address)
            return;

        const to_us = packet.broadcast or packet.to == ygg.address;
        if (to_us)
            ygg.stayAwake(now +% p.lingerMs(p.frame_budget));

        const learn = ygg.joining_until != null or (!packet.broadcast and packet.to == ygg.address) or isHello(packet);
        const neighbor = ygg.forwarding_table.neighborByAddr(packet.from) orelse
            (if (learn) ygg.learnNeighbor(packet.from) catch return else return);

        neighbor.heard_at = now;
        neighbor.hops = packet.hops;

        if (!to_us and !link_layer.isLinkOnly(packet))
            neighbor.busy_until = now +% p.backoffMs();

        if (packet.wake_phase) |phase| {
            if (packet.period) |period|
                neighbor.period_ms = @as(u32, period) * power.PERIOD_UNIT_MS;
            neighbor.sched_known = neighbor.period_ms != 0;
            if (neighbor.sched_known) {
                neighbor.next_window = now -% p.frameMs(frameLen(packet)) +% NetworkPacket.wakeInMs(phase, neighbor.period_ms);
                neighbor.synced_at = now;
            }
        } else {
            neighbor.period_ms = 0;
            neighbor.sched_known = true;
        }

        if (ygg.root) |current| {
            if (!ygg.is_root and current.via == packet.from)
                ygg.followParent(neighbor, packet.hops, now);
        }
    }

    fn isHello(packet: *const NetworkPacket) bool {
        const app = AppPacket.parse(packet.body()) orelse return false;
        return app.op == .hello and !packet.ack;
    }

    fn followParent(ygg: *Yggdrasil, parent: *routing.MessageQueueMap, hops: u8, now: u32) void {
        const p = ygg.power.?;
        if (hops == NetworkPacket.NO_HOPS or hops +| 1 > p.max_hops) {
            ygg.loseRoot(now);
            return;
        }

        const current = &ygg.root.?;
        current.heard_at = now;
        if (current.hops != hops + 1) {
            current.hops = hops + 1;
            ygg.forwarding_table.setRoute(current.addr, parent.mq_idx, current.hops) catch {};
        }

        ygg.alignWindow(now);
    }

    fn alignWindow(ygg: *Yggdrasil, now: u32) void {
        const p = ygg.power orelse return;
        if (!p.sleepy() or ygg.is_root)
            return;

        const current = ygg.root orelse return;
        const parent = ygg.forwarding_table.neighborByAddr(current.via) orelse return;
        if (alwaysListening(parent))
            return;

        const period = p.periodMs();
        const lead = p.windowMs() + p.radio_wake_ms + p.baseGuardMs();
        const target = parent.next_window -% lead;

        const ours = ygg.ownWindowStart(now);
        const offset = ours -% power.windowAt(target, period, ours);
        const tolerance = @max(p.windowMs() / 4, 4 * p.baseGuardMs());
        if (offset <= tolerance or period - offset <= tolerance)
            return;

        ygg.old_window = ours;
        ygg.old_window_until = now +% @as(u32, p.legacy_periods) * period;
        ygg.own_window = target;
        ygg.next_beacon_at = null;
    }

    fn loseRoot(ygg: *Yggdrasil, now: u32) void {
        const current = ygg.root orelse return;
        ygg.lost_root = current;
        ygg.lost_root_at = now;
        ygg.forwarding_table.removeRoute(current.addr);
        ygg.root = null;
        ygg.next_beacon_at = null;
        ygg.next_join_at = now +% ygg.joinJitter();
        ygg.join_backoff_ms = 0;
        ygg.recomputeRoutes();
    }

    fn feasible(ygg: *const Yggdrasil, ann: AppPacket.RootAnnouncement, now: u32) bool {
        const p = ygg.power orelse return true;
        const lost = ygg.lost_root orelse return true;
        if (lost.addr != ann.root or routing.seqNewer(ann.seq, lost.seq))
            return true;
        if (ann.seq != lost.seq)
            return false;
        if (ann.hops < lost.hops)
            return true;
        return reached(now, ygg.lost_root_at +% p.rootHolddownMs());
    }

    fn currentAnnouncement(ygg: *const Yggdrasil) ?AppPacket.RootAnnouncement {
        if (ygg.is_root)
            return .{ .root = ygg.address, .seq = ygg.root_seq, .hops = 0 };
        const current = ygg.root orelse return null;
        return .{ .root = current.addr, .seq = current.seq, .hops = current.hops };
    }

    fn markAnnounce(ygg: *Yggdrasil, except: ?Address, hops: u8) void {
        const ft = &ygg.forwarding_table;
        for (ft.output_map[0..ft.num_registered_output_map]) |*neighbor| {
            if (except != null and neighbor.addr == except.?)
                continue;
            if (neighbor.hops == NetworkPacket.NO_HOPS or neighbor.hops >= hops)
                neighbor.announce_pending = true;
        }
    }

    fn directPacket(ygg: *const Yggdrasil, to: Address, op: AppPacket.Opcode) NetworkPacket {
        var packet = NetworkPacket{
            .from = ygg.address,
            .to = to,
            .origin = ygg.address,
            .dest = to,
            .len = 1,
        };
        packet.payload[0] = @backingInt(op);
        return packet;
    }

    fn refill(ygg: *Yggdrasil) void {
        const mq = &ygg.outgoing_packets;
        const ft = &ygg.forwarding_table;
        for (ft.output_map[0..ft.num_registered_output_map]) |*neighbor| {
            if (neighbor.hello_pending) {
                const hello = ygg.directPacket(neighbor.addr, .hello);
                if (mq.pushMessage(neighbor.mq_idx, hello, MessageQueue.PRIORITY_HIGH)) |_| {
                    resetLink(neighbor);
                    neighbor.hello_pending = false;
                } else |_| {}
            }

            if (neighbor.announce_pending) {
                const ann = ygg.currentAnnouncement() orelse {
                    neighbor.announce_pending = false;
                    continue;
                };
                var packet = ygg.directPacket(neighbor.addr, .im_a_root);
                packet.len = 1 + AppPacket.RootAnnouncement.LEN;
                ann.write(packet.payload[1..][0..AppPacket.RootAnnouncement.LEN]);
                if (mq.pushMessage(neighbor.mq_idx, packet, MessageQueue.PRIORITY_HIGH)) |_| {
                    neighbor.announce_pending = false;
                } else |_| {}
            }
        }
    }

    fn maintainJoin(ygg: *Yggdrasil, now: u32) YggdrasilError!bool {
        if (ygg.is_root)
            return false;

        if (ygg.root != null) {
            ygg.joining_until = null;
            return false;
        }

        const p = ygg.power.?;

        if (ygg.joining_until) |until| {
            if (reached(now, until)) {
                ygg.joining_until = null;
                if (ygg.adoptCandidate(now))
                    return false;
                ygg.finishJoin(now);
                return false;
            }
            if (ygg.hellos_left == 0 or !reached(now, ygg.next_hello_at))
                return false;
            ygg.hellos_left -= 1;
            ygg.next_hello_at = now +% p.helloSpacingMs() +% ygg.joinJitter();
            try ygg.sayHello();
            return true;
        }

        const start = ygg.next_join_at orelse blk: {
            const at = now +% ygg.joinJitter();
            ygg.next_join_at = at;
            break :blk at;
        };
        if (!reached(now, start))
            return false;

        ygg.joining_until = now +% p.scanMs();
        ygg.join_candidate = null;
        ygg.hellos_left = @max(p.join_hellos, 1) - 1;
        ygg.next_hello_at = now +% p.helloSpacingMs() +% ygg.joinJitter();
        try ygg.sayHello();
        return true;
    }

    fn maintainBeacon(ygg: *Yggdrasil, now: u32) void {
        const p = ygg.power.?;
        const ann = ygg.currentAnnouncement() orelse {
            ygg.next_beacon_at = null;
            return;
        };

        if (ygg.is_root and p.root_beacon_ms != 0) {
            if (ygg.atCapacity())
                return;

            const due = ygg.next_beacon_at orelse now;
            if (!reached(now, due) or ygg.pending_announce != null)
                return;

            ygg.queueAnnouncement(ann, now);
            ygg.next_beacon_at = now +% p.root_beacon_ms +% ygg.random(p.root_beacon_ms / 4);
            return;
        }

        if (!p.sleepy() or p.beacon_periods == 0)
            return;

        const due = ygg.next_beacon_at orelse blk: {
            const at = ygg.beaconAt(p, now, p.periodMs());
            ygg.next_beacon_at = at;
            break :blk at;
        };
        if (!reached(now, due) or ygg.pending_announce != null)
            return;

        ygg.queueAnnouncement(ann, now);
        ygg.next_beacon_at = ygg.beaconAt(p, now, p.beaconIntervalMs());
    }

    fn beaconAt(ygg: *Yggdrasil, p: Power, now: u32, ahead: u32) u32 {
        const start = ygg.ownWindowStart(now +% ahead);
        return start +% p.windowMs() +% ygg.random(p.baseGuardMs());
    }

    fn outsideOwnWindow(ygg: *Yggdrasil, at: u32) u32 {
        const p = ygg.power orelse return at;
        if (!p.sleepy() or ygg.is_root or !ygg.own_window_set)
            return at;
        const start = ygg.ownWindowStart(at);
        if (at -% start < p.windowMs())
            return start +% p.windowMs();
        return at;
    }

    fn finishJoin(ygg: *Yggdrasil, now: u32) void {
        const p = ygg.power.?;
        const ft = &ygg.forwarding_table;
        for (ft.output_map[0..ft.num_registered_output_map]) |*neighbor| {
            if (neighbor.hops != NetworkPacket.NO_HOPS)
                neighbor.hello_pending = true;
        }

        const first = @max(p.periodMs(), 4 * p.windowMs());
        const step = if (ygg.join_backoff_ms == 0) first else ygg.join_backoff_ms *| 2;
        const cap = if (ygg.ever_rooted) p.join_backoff_max_ms else p.join_backoff_fresh_max_ms;
        ygg.join_backoff_ms = @min(step, @max(cap, first));
        ygg.next_join_at = now +% ygg.join_backoff_ms +% ygg.joinJitter();
    }

    fn joinJitter(ygg: *Yggdrasil) u32 {
        const p = ygg.power orelse return 0;
        return ygg.random(2 * p.windowMs());
    }

    fn reportDueAt(ygg: *const Yggdrasil, p: Power) u32 {
        if (ygg.report_at) |t| return t;
        if (!ygg.reported_once) return ygg.currentTime();
        return ygg.reported_at +% p.report_refresh_ms;
    }

    fn maintainReport(ygg: *Yggdrasil, now: u32) void {
        const p = ygg.power.?;
        if (!ygg.topology_reporting or ygg.is_root)
            return;

        const current = ygg.root orelse return;
        if (!reached(now, ygg.reportDueAt(p)))
            return;

        const ft = &ygg.forwarding_table;
        var own: [routing.MAX_NEIGHBORS]Address = undefined;
        for (ft.output_map[0..ft.num_registered_output_map], 0..) |n, i| own[i] = n.addr;

        var buf: [NetworkPacket.MAX_PAYLOAD_SIZE]u8 = undefined;
        buf[0] = @backingInt(AppPacket.Opcode.topology_info);
        const info = AppPacket.TopologyInfo.write(ygg.address, ygg.topology_seq, own[0..ft.num_registered_output_map], buf[1..]) catch return;

        ygg.send(current.addr, buf[0 .. 1 + info.len], MessageQueue.PRIORITY_LOW) catch return;
        ygg.report_at = null;
        ygg.reported_at = now;
        ygg.reported_once = true;
    }

    fn expireNeighbors(ygg: *Yggdrasil, now: u32) void {
        const p = ygg.power.?;
        if (p.neighbor_timeout_ms == 0)
            return;

        const ft = &ygg.forwarding_table;
        const via: ?Address = if (ygg.root) |r| r.via else null;
        var i = ft.num_registered_output_map;
        while (i > 0) {
            i -= 1;
            const neighbor = &ft.output_map[i];
            if (!neighbor.sched_known or now -% neighbor.heard_at < p.neighbor_timeout_ms)
                continue;
            if (via != null and neighbor.addr == via.?)
                continue;
            if (ygg.outgoing_packets.tx_buffers[neighbor.mq_idx] != null)
                continue;
            ygg.dropNeighbor(neighbor.addr);
        }
    }

    fn helloHeard(ygg: *Yggdrasil, addr: Address) void {
        const p = ygg.power.?;
        const known = ygg.forwarding_table.neighborByAddr(addr) != null;
        const neighbor = ygg.learnNeighbor(addr) catch return;
        if (known)
            resetLink(neighbor);

        if (ygg.currentAnnouncement() == null)
            return;

        neighbor.announce_pending = true;
        neighbor.tx_at = ygg.currentTime() +% ygg.random(p.backoffMs());
    }

    fn learnReverse(ygg: *Yggdrasil, packet: *const NetworkPacket) void {
        const p = ygg.power orelse return;
        if (packet.origin == packet.from or packet.origin == ygg.address)
            return;

        const ft = &ygg.forwarding_table;
        if (ft.route(packet.origin) != null or ft.num_forwards + 1 >= routing.MAX_NEIGHBORS)
            return;

        const via = ft.neighborByAddr(packet.from) orelse return;
        ft.setRoute(packet.origin, via.mq_idx, p.reverse_route_hops) catch {};
    }

    fn handleDirect(ygg: *Yggdrasil, packet: *const NetworkPacket) void {
        const app = AppPacket.parse(packet.body()) orelse return;
        switch (app.op) {
            .im_a_root => ygg.handleRootAnnouncement(packet.from, app.payload),
            .topology_info => {
                if (ygg.topology_reporting and ygg.is_root)
                    ygg.handleTopologyInfo(packet.from, app.payload);
            },
            .hello => {
                if (ygg.power == null or packet.ack)
                    return;
                if (ygg.currentAnnouncement() == null)
                    return;
                if (ygg.forwarding_table.neighborByAddr(packet.from)) |neighbor|
                    neighbor.announce_pending = true;
            },
            else => {},
        }
    }

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

    pub fn dropNeighbor(ygg: *Yggdrasil, addr: Address) void {
        const neighbor = ygg.forwarding_table.neighborByAddr(addr) orelse return;

        ygg.outgoing_packets.clearSlot(neighbor.mq_idx);
        ygg.forwarding_table.removeNeighbor(addr);

        if (ygg.root) |current| {
            if (current.via == addr)
                ygg.loseRoot(ygg.currentTime());
        }

        ygg.neighborsChanged(false);

        if (ygg.neighbor_lost_cb) |cb|
            cb(addr);
    }

    fn writePacket(ygg: *Yggdrasil, packet: *NetworkPacket) YggdrasilError!void {
        var buf: [TX_BUFFER_SIZE]u8 = undefined;
        ygg.stamp(packet);
        try ygg.write_bytes_fn(packet.toBuffer(&buf));

        if (ygg.power) |p|
            ygg.stayAwake(ygg.currentTime() +% p.lingerMs(frameLen(packet)));
    }

    pub fn registerNeighbor(ygg: *Yggdrasil, addr: Address, slot: usize) NeighborError!*routing.MessageQueueMap {
        const known = ygg.forwarding_table.neighborByAddr(addr) != null;
        const neighbor = try ygg.forwarding_table.registerNeighbor(addr, slot);

        const mq = &ygg.outgoing_packets;
        if (slot + 1 > mq.registered_nodes)
            mq.registered_nodes = slot + 1;

        if (!known) {
            if (ygg.power != null and ygg.is_root)
                neighbor.announce_pending = true;
            ygg.neighborsChanged(true);
        }

        return neighbor;
    }

    pub fn announceTopology(ygg: *Yggdrasil) void {
        if (ygg.topology_reporting and !ygg.is_root)
            ygg.report_at = ygg.currentTime();

        if (!ygg.topology_flooding)
            return;

        ygg.topology_seq +%= 1;
        ygg.own_flood_pending = true;
        ygg.own_flood_at = ygg.currentTime();
    }

    fn neighborsChanged(ygg: *Yggdrasil, added: bool) void {
        if (ygg.topology_reporting and !ygg.is_root) {
            const p = ygg.power orelse Power{};
            ygg.topology_seq +%= 1;
            if (ygg.report_at == null)
                ygg.report_at = ygg.currentTime() +% p.report_holddown_ms;
        }

        if (!ygg.topology_flooding) {
            ygg.recomputeRoutes();
            return;
        }

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
            var own: [routing.MAX_NEIGHBORS]Address = undefined;
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

    fn topologyPacket(ygg: *const Yggdrasil, origin: Address, seq: u16, neighbors: []const Address) NetworkPacket {
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

    fn keepsTopology(ygg: *const Yggdrasil) bool {
        return ygg.topology_flooding or (ygg.topology_reporting and ygg.is_root);
    }

    fn handleTopologyInfo(ygg: *Yggdrasil, from: Address, payload: []const u8) void {
        if (!ygg.keepsTopology())
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

        var neighbors: [routing.MAX_NEIGHBORS]Address = undefined;
        const n = @min(info.count(), neighbors.len);
        for (0..n) |i| neighbors[i] = info.neighbor(i);

        const now = ygg.currentTime();
        const entry = (ygg.topology.update(info.origin, info.seq, neighbors[0..n], now) catch return) orelse return;
        if (ygg.topology_flooding) {
            entry.flood_pending = true;
            entry.flood_at = now +% ygg.random(ygg.announce_jitter_ms);
        }

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
        if (!ygg.keepsTopology())
            return;

        const ft = &ygg.forwarding_table;
        const root_addr: ?Address = if (ygg.root) |r| r.addr else null;
        ft.removeRoutesExcept(root_addr);

        var own: [routing.MAX_NEIGHBORS]Address = undefined;
        for (ft.output_map[0..ft.num_registered_output_map], 0..) |n, i| own[i] = n.addr;

        var paths: [routing.TopologyGraph.MAX_VERTICES]routing.Path = undefined;
        const n = ygg.topology.shortestPaths(ygg.address, own[0..ft.num_registered_output_map], &paths);

        for (paths[0..n]) |path| {
            if (path.cost < 2 or root_addr == path.dest) continue;
            const via = ft.neighborByAddr(path.first_hop) orelse continue;
            ft.setRoute(path.dest, via.mq_idx, path.cost) catch break;
        }
    }

    pub fn atCapacity(ygg: *const Yggdrasil) bool {
        return ygg.is_root and ygg.max_children != 0 and
            ygg.forwarding_table.num_registered_output_map >= ygg.max_children;
    }

    pub fn learnNeighbor(ygg: *Yggdrasil, addr: Address) NeighborError!*routing.MessageQueueMap {
        const ft = &ygg.forwarding_table;

        if (ft.neighborByAddr(addr)) |existing|
            return existing;

        if (ygg.atCapacity())
            return error.AtCapacity;

        const slot = ft.freeSlot() orelse return error.TooManyNeighbors;
        return ygg.registerNeighbor(addr, slot);
    }

    pub fn send(ygg: *Yggdrasil, dest: Address, payload: []const u8, priority: u8) SendError!void {
        const found = ygg.routeTo(dest) orelse return error.NoRoute;

        var packet = NetworkPacket{
            .from = ygg.address,
            .to = found.neighbor.addr,
            .origin = ygg.address,
            .dest = dest,
            .ttl = found.hops +| ygg.hop_slack,
        };
        try packet.setPayload(payload);

        try ygg.enqueue(found.neighbor, packet, priority);
    }

    fn enqueue(ygg: *Yggdrasil, neighbor: *routing.MessageQueueMap, packet: NetworkPacket, priority: u8) MessageQueue.PushError!void {
        if (ygg.merge_readings and ygg.mergeQueued(neighbor, &packet))
            return;
        try ygg.outgoing_packets.pushMessage(neighbor.mq_idx, packet, priority);
    }

    fn mergeQueued(ygg: *Yggdrasil, neighbor: *routing.MessageQueueMap, incoming: *const NetworkPacket) bool {
        if (incoming.broadcast)
            return false;

        const mq = &ygg.outgoing_packets;
        if (!neighbor.sent) {
            if (mq.tx_buffers[neighbor.mq_idx]) |*held| {
                if (ygg.mergeReadings(held, incoming))
                    return true;
            }
        }

        var i: usize = 0;
        while (mq.queued(neighbor.mq_idx, i)) |waiting| : (i += 1) {
            if (ygg.mergeReadings(waiting, incoming))
                return true;
        }
        return false;
    }

    fn mergeReadings(ygg: *const Yggdrasil, target: *NetworkPacket, incoming: *const NetworkPacket) bool {
        if (target.broadcast or target.dest != incoming.dest)
            return false;

        var held_buf: [NetworkPacket.MAX_PAYLOAD_SIZE]u8 = undefined;
        var new_buf: [NetworkPacket.MAX_PAYLOAD_SIZE]u8 = undefined;
        const held = readingEntries(target, &held_buf) orelse return false;
        const new = readingEntries(incoming, &new_buf) orelse return false;

        const len = 1 + held.len + new.len;
        if (len > NetworkPacket.MAX_PAYLOAD_SIZE)
            return false;

        var out: [NetworkPacket.MAX_PAYLOAD_SIZE]u8 = undefined;
        out[0] = @backingInt(AppPacket.Opcode.batched_readings);
        @memcpy(out[1..][0..held.len], held);
        @memcpy(out[1 + held.len ..][0..new.len], new);

        target.setPayload(out[0..len]) catch return false;
        target.origin = ygg.address;
        target.ttl = @max(target.ttl, incoming.ttl);
        return true;
    }

    fn readingEntries(packet: *const NetworkPacket, buf: []u8) ?[]const u8 {
        const app = AppPacket.parse(packet.body()) orelse return null;
        switch (app.op) {
            .compact_readings => {
                _ = AppPacket.CompactReadings.parse(app.payload) orelse return null;
                buf[0] = packet.origin;
                @memcpy(buf[1..][0..app.payload.len], app.payload);
                return buf[0 .. 1 + app.payload.len];
            },
            .batched_readings => {
                if (!AppPacket.ReadingBatch.valid(app.payload))
                    return null;
                @memcpy(buf[0..app.payload.len], app.payload);
                return buf[0..app.payload.len];
            },
            else => return null,
        }
    }

    fn routeTo(ygg: *Yggdrasil, dest: Address) ?routing.Route {
        if (ygg.root) |current| {
            if (current.addr == dest and current.via != dest) {
                if (ygg.forwarding_table.neighborByAddr(current.via)) |via|
                    return .{ .neighbor = via, .hops = current.hops };
            }
        }
        return ygg.forwarding_table.route(dest);
    }

    pub fn rootAddress(ygg: *const Yggdrasil) ?Address {
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

        if (ygg.power != null) {
            ygg.markAnnounce(null, 0);
            return;
        }

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

    fn handleRootAnnouncement(ygg: *Yggdrasil, from: Address, payload: []const u8) void {
        if (ygg.is_root)
            return;

        const ann = AppPacket.RootAnnouncement.parse(payload) orelse return;
        if (ann.root == ygg.address)
            return;

        const neighbor = ygg.learnNeighbor(from) catch return;
        const hops = ann.hops +| 1;
        const now = ygg.currentTime();

        if (ygg.power) |p| {
            if (hops > p.max_hops)
                return;
            if (ygg.root == null and !ygg.feasible(ann, now))
                return;
            if (ygg.root == null and ygg.joining_until != null and hops > 1) {
                ygg.considerCandidate(ann, from, hops);
                return;
            }
        }

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

        ygg.adoptRoot(ann, neighbor, hops, now);
    }

    fn betterRoot(best: JoinCandidate, ann: AppPacket.RootAnnouncement, hops: u8) bool {
        if (best.ann.root != ann.root)
            return hops < best.hops;
        if (routing.seqNewer(ann.seq, best.ann.seq))
            return true;
        return ann.seq == best.ann.seq and hops < best.hops;
    }

    fn considerCandidate(ygg: *Yggdrasil, ann: AppPacket.RootAnnouncement, via: Address, hops: u8) void {
        if (ygg.join_candidate) |best| {
            if (!betterRoot(best, ann, hops))
                return;
        }
        ygg.join_candidate = .{ .ann = ann, .via = via, .hops = hops };
    }

    fn adoptCandidate(ygg: *Yggdrasil, now: u32) bool {
        const candidate = ygg.join_candidate orelse return false;
        ygg.join_candidate = null;

        const neighbor = ygg.forwarding_table.neighborByAddr(candidate.via) orelse return false;
        ygg.adoptRoot(candidate.ann, neighbor, candidate.hops, now);
        return ygg.root != null;
    }

    fn adoptRoot(ygg: *Yggdrasil, ann: AppPacket.RootAnnouncement, via: *routing.MessageQueueMap, hops: u8, now: u32) void {
        const previous = ygg.root;
        const from = via.addr;

        ygg.forwarding_table.setRoute(ann.root, via.mq_idx, hops) catch return;
        ygg.root = .{
            .addr = ann.root,
            .via = from,
            .hops = hops,
            .seq = ann.seq,
            .heard_at = now,
        };

        if (ygg.power == null) {
            ygg.queueAnnouncement(
                .{ .root = ann.root, .seq = ann.seq, .hops = hops },
                now +% ygg.random(ygg.announce_jitter_ms),
            );
        } else {
            const changed = if (previous) |prev| prev.addr != ann.root or prev.seq != ann.seq else true;
            if (changed) {
                ygg.markAnnounce(from, hops);
                ygg.next_beacon_at = null;
            }
            ygg.joining_until = null;
            ygg.join_candidate = null;
            ygg.hellos_left = 0;
            ygg.join_backoff_ms = 0;
            ygg.ever_rooted = true;
            ygg.lost_root = null;
            ygg.alignWindow(now);
        }

        ygg.recomputeRoutes();
    }

    fn refreshDirectRoot(ygg: *Yggdrasil, from: Address) void {
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

        ygg.loseRoot(at);
    }

    pub fn sendApp(ygg: *Yggdrasil, dest: Address, app: AppPacket, priority: u8) SendError!void {
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

    fn replyHello(ygg: *Yggdrasil, addr: Address) (NeighborError || SendError)!void {
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

        const found = ygg.routeTo(packet.dest) orelse return;
        const hop = found.neighbor;

        if (hop.addr == packet.from)
            return;

        var forwarded = packet;
        forwarded.from = ygg.address;
        forwarded.to = hop.addr;
        forwarded.ttl = packet.ttl - 1;

        ygg.enqueue(hop, forwarded, MessageQueue.PRIORITY_LOW) catch {};
    }

    fn handleBroadcast(ygg: *Yggdrasil, packet: NetworkPacket) void {
        if (packet.from == ygg.address)
            return;

        if (AppPacket.parse(packet.body())) |app| {
            switch (app.op) {
                .hello => {
                    if (ygg.power != null) {
                        ygg.helloHeard(packet.from);
                    } else {
                        ygg.replyHello(packet.from) catch {};
                        ygg.answerHello();
                    }
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
        ygg.noteFrame(&packet, ygg.currentTime());
        ygg.refreshDirectRoot(packet.from);

        if (packet.broadcast) {
            ygg.handleBroadcast(packet);
            return;
        }

        if (packet.to != ygg.address)
            return;

        if (packet.from != ygg.address) {
            _ = ygg.learnNeighbor(packet.from) catch |err| switch (err) {
                error.AtCapacity => return,
                else => {},
            };
        }

        if (ygg.forwarding_table.neighborByAddr(packet.from)) |neighbor| {
            if (ygg.power != null and isHello(&packet))
                resetLink(neighbor);

            if (link_layer.isLinkOnly(&packet)) {
                link_layer.processAck(ygg, neighbor, packet.nesn);
                return;
            }

            if (!link_layer.linkLayerProcess(ygg, neighbor, packet.sn, packet.nesn))
                return;
        }

        ygg.learnReverse(&packet);

        if (packet.dest == ygg.address) {
            ygg.handleDirect(&packet);
            ygg.result_cb(packet);
        } else {
            ygg.forward(packet);
        }
    }

    pub fn readStream(ygg: *Yggdrasil) YggdrasilError!void {
        const frame = try ygg.read_bytes_fn(ygg.buffer);
        if (frame.len != 0)
            ygg.handleFrame(frame);
    }

    pub fn handleFrame(ygg: *Yggdrasil, frame: []const u8) void {
        const packet = NetworkPacket.parse(frame) orelse return;
        ygg.handle_network_packet(packet);
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

    fn node(addr: Address) Yggdrasil {
        return .{
            .read_bytes_fn = read,
            .write_bytes_fn = write,
            .result_cb = cb,
            .address = addr,
            .topology_flooding = false,
        };
    }

    fn hear(ygg: *Yggdrasil) !void {
        try std.testing.expect(NetworkPacket.parse(wire[0..wire_len]) != null);
        ygg.handleFrame(wire[0..wire_len]);
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
    try std.testing.expectEqual(@as(Address, 1), got.origin);
    try std.testing.expectEqual(@as(Address, 3), got.dest);
    try std.testing.expectEqual(@as(Address, 2), got.from);
    try std.testing.expectEqualSlices(u8, "hi", got.body());

    try TestNet.transmit(&c, &.{&b});
    try std.testing.expect(b.outgoing_packets.allEmpty());

    try std.testing.expectError(error.NoRoute, b.send(99, "x", MessageQueue.PRIORITY_LOW));
}

const TestClock = struct {
    var time: u32 = 0;
    var lost: ?Address = null;

    fn now() u32 {
        return time;
    }

    fn onLost(addr: Address) void {
        lost = addr;
    }

    fn node(addr: Address) Yggdrasil {
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

    try std.testing.expectEqual(NetworkPacket.BASE_HEADER_LEN + NetworkPacket.MAX_PAYLOAD_SIZE, TestNet.wire_len);
    try std.testing.expect(NetworkPacket.MAX_HEADER_LEN + NetworkPacket.MAX_PAYLOAD_SIZE <= NetworkPacket.MAX_FRAME_LEN);
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
    try std.testing.expectEqual(@as(?Address, 2), TestClock.lost);
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
    try std.testing.expectEqual(NetworkPacket.BASE_HEADER_LEN, TestNet.wire_len);
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

fn announcementFrom(ygg: *Yggdrasil, root: Address, seq: u16, hops: u8) void {
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

    try std.testing.expectEqual(@as(?Address, 1), b.rootAddress());
    try std.testing.expectEqual(@as(u8, 1), b.root.?.hops);
    try std.testing.expect(c.rootAddress() == null);

    try TestNet.transmit(&b, &.{ &a, &c });

    try std.testing.expectEqual(@as(?Address, 1), c.rootAddress());
    try std.testing.expectEqual(@as(u8, 2), c.root.?.hops);
    try std.testing.expectEqual(@as(Address, 2), c.root.?.via);
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
    try std.testing.expectEqual(@as(Address, 3), got.origin);
    try std.testing.expectEqual(@as(Address, 1), got.dest);
    try std.testing.expectEqual(@as(u8, 1), got.ttl);
    try std.testing.expectEqualSlices(u8, "r", got.body());
}

const Mesh = struct {
    nodes: []const *Yggdrasil,
    links: []const [2]Address,

    fn hears(mesh: Mesh, a: Address, b: Address) bool {
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

fn meshNode(addr: Address) Yggdrasil {
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

    try std.testing.expectEqual(@as(Address, 2), n1.forwarding_table.route(4).?.neighbor.addr);
    try std.testing.expectEqual(@as(u8, 3), n1.forwarding_table.route(4).?.hops);
    try std.testing.expectEqual(@as(u8, 2), n1.forwarding_table.route(3).?.hops);
    try std.testing.expectEqual(@as(Address, 3), n4.forwarding_table.route(1).?.neighbor.addr);
    try std.testing.expectEqual(@as(u8, 3), n4.forwarding_table.route(1).?.hops);
    try std.testing.expectEqual(@as(Address, 3), n2.forwarding_table.route(4).?.neighbor.addr);
    try std.testing.expectEqual(@as(Address, 2), n3.forwarding_table.route(1).?.neighbor.addr);

    TestNet.delivered = null;
    try n1.send(4, "far", MessageQueue.PRIORITY_LOW);
    try mesh.settle();

    const got = TestNet.delivered.?;
    try std.testing.expectEqual(@as(Address, 1), got.origin);
    try std.testing.expectEqual(@as(Address, 4), got.dest);
    try std.testing.expectEqualSlices(u8, "far", got.body());

    TestNet.delivered = null;
    try n4.send(1, "back", MessageQueue.PRIORITY_LOW);
    try mesh.settle();
    try std.testing.expectEqual(@as(Address, 1), TestNet.delivered.?.dest);
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

    try std.testing.expectEqual(@as(Address, 2), n1.forwarding_table.route(3).?.neighbor.addr);
    try std.testing.expectEqual(@as(u8, 2), n1.forwarding_table.route(3).?.hops);

    mesh.links = &.{ .{ 1, 2 }, .{ 1, 4 }, .{ 4, 5 }, .{ 5, 3 } };
    mesh.cut(&n2, &n3);
    try mesh.settle();

    try std.testing.expectEqual(@as(Address, 4), n1.forwarding_table.route(3).?.neighbor.addr);
    try std.testing.expectEqual(@as(u8, 3), n1.forwarding_table.route(3).?.hops);
    try std.testing.expectEqual(@as(Address, 1), n2.forwarding_table.route(3).?.neighbor.addr);
    try std.testing.expectEqual(@as(u8, 4), n2.forwarding_table.route(3).?.hops);

    TestNet.delivered = null;
    try n2.send(3, "around", MessageQueue.PRIORITY_LOW);
    try mesh.settle();
    try std.testing.expectEqual(@as(Address, 3), TestNet.delivered.?.dest);
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
    try std.testing.expectEqual(@as(Address, 10), c.root.?.via);

    announcementFrom(&b, 1, 5, 1);
    try TestNet.transmit(&b, &.{&c});
    try std.testing.expectEqual(@as(u8, 2), c.root.?.hops);
    try std.testing.expectEqual(@as(Address, 20), c.root.?.via);

    announcementFrom(&a, 1, 5, 0);
    try TestNet.transmit(&a, &.{&c});
    try std.testing.expectEqual(@as(u8, 1), c.root.?.hops);
    try std.testing.expectEqual(@as(Address, 10), c.forwarding_table.nextHop(1).?.addr);

    announcementFrom(&b, 1, 4, 0);
    try TestNet.transmit(&b, &.{&c});
    try std.testing.expectEqual(@as(Address, 10), c.root.?.via);

    announcementFrom(&b, 1, 6, 7);
    try TestNet.transmit(&b, &.{&c});
    try std.testing.expectEqual(@as(Address, 20), c.root.?.via);
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
    try std.testing.expectEqual(@as(?Address, 1), b.rootAddress());

    TestClock.time = 900;
    try a.sayHello();
    try TestNet.hear(&b);

    TestClock.time = 1800;
    _ = try b.requestWrite();
    try std.testing.expectEqual(@as(?Address, 1), b.rootAddress());

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
    try std.testing.expectEqual(@as(?Address, 1), b.rootAddress());
    b.pending_announce = null;

    try c.sayHello();
    try TestNet.hear(&b);
    try std.testing.expect(b.pending_announce != null);

    TestClock.time = b.announce_at;
    try TestNet.transmit(&b, &.{&c});
    try std.testing.expectEqual(@as(?Address, 1), c.rootAddress());
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
    try std.testing.expectEqual(@as(?Address, 1), b.rootAddress());

    TestClock.time = 999;
    _ = try b.requestWrite();
    try std.testing.expectEqual(@as(?Address, 1), b.rootAddress());

    TestClock.time = 1000;
    _ = try b.requestWrite();
    try std.testing.expect(b.rootAddress() == null);
    try std.testing.expect(b.forwarding_table.forwarding_table[0..b.forwarding_table.num_forwards].len == 0);
    try std.testing.expectError(error.NoRoute, b.sendToRoot("x", MessageQueue.PRIORITY_LOW));
}

test "a planned send stays due when the loop polls late in the window" {
    TestClock.time = 0;

    var a = TestClock.node(1);
    a.power = .{ .period_ms = 10_000, .radio = .{ .spreading_factor = 7 } };
    const neighbor = try a.registerNeighbor(2, 0);
    neighbor.sched_known = true;
    neighbor.period_ms = 10_000;
    neighbor.next_window = 1000;

    const len: usize = 30;
    const t = a.plannedTx(neighbor, 1000, len);
    try std.testing.expect(Yggdrasil.after(t, 1000));
    try std.testing.expectEqual(t, a.plannedTx(neighbor, t + 5, len));
    try std.testing.expect(a.sendable(neighbor, t + 5, len));
}

test "joiners keep the shortest root offered during a scan" {
    TestClock.time = 0;

    var a = TestClock.node(10);
    var b = TestClock.node(20);
    var c = TestClock.node(30);
    c.power = .{ .period_ms = 1000 };
    c.joining_until = 5000;

    announcementFrom(&a, 1, 5, 2);
    try TestNet.transmit(&a, &.{&c});
    try std.testing.expect(c.root == null);

    announcementFrom(&b, 1, 5, 1);
    try TestNet.transmit(&b, &.{&c});

    announcementFrom(&a, 1, 5, 3);
    try TestNet.transmit(&a, &.{&c});
    try std.testing.expect(c.root == null);

    TestClock.time = 5000;
    _ = try c.requestWrite();
    try std.testing.expectEqual(@as(?Address, 1), c.rootAddress());
    try std.testing.expectEqual(@as(Address, 20), c.root.?.via);
    try std.testing.expectEqual(@as(u8, 2), c.root.?.hops);
    try std.testing.expect(c.joining_until == null);
    try std.testing.expect(c.join_candidate == null);
}

test "joiners adopt a direct root without waiting for the scan to end" {
    TestClock.time = 0;

    var a = TestClock.node(1);
    var c = TestClock.node(30);
    c.power = .{ .period_ms = 1000 };
    c.joining_until = 5000;

    announcementFrom(&a, 1, 5, 0);
    try TestNet.transmit(&a, &.{&c});
    try std.testing.expectEqual(@as(?Address, 1), c.rootAddress());
    try std.testing.expectEqual(@as(u8, 1), c.root.?.hops);
    try std.testing.expect(c.joining_until == null);
}

test "joiners advertise their wake schedule while scanning" {
    TestClock.time = 0;

    var b = TestClock.node(2);
    var c = TestClock.node(3);
    b.power = .{ .period_ms = 1000 };
    c.power = .{ .period_ms = 1000 };
    c.joining_until = 5000;

    try c.sayHello();
    try TestNet.hear(&b);

    const joiner = b.forwarding_table.neighborByAddr(3).?;
    try std.testing.expectEqual(@as(u32, 1000), joiner.period_ms);
    try std.testing.expect(!Yggdrasil.alwaysListening(joiner));
}

test "sleepy nodes hold sends to always-on neighbors until their own window closes" {
    TestClock.time = 0;

    var n = TestClock.node(2);
    n.power = .{ .period_ms = 60_000, .radio = .{ .spreading_factor = 7 } };
    n.own_window = 1000;
    n.own_window_set = true;
    const root = try n.registerNeighbor(1, 0);
    const p = n.power.?;

    try std.testing.expectEqual(@as(u32, 1000 + p.windowMs()), n.plannedTx(root, 1100, 20));
    try std.testing.expectEqual(@as(u32, 500), n.plannedTx(root, 500, 20));
    try std.testing.expectEqual(@as(u32, 1000 + p.windowMs() + 5), n.plannedTx(root, 1000 + p.windowMs() + 5, 20));
}

test "a unicast send keeps the radio quiet until its ack can come back" {
    TestClock.time = 0;

    var n = TestClock.node(2);
    n.power = .{ .period_ms = 60_000, .radio = .{ .spreading_factor = 7 } };
    n.own_window = 1000;
    n.own_window_set = true;
    const parent = try n.registerNeighbor(1, 0);
    n.root = .{ .addr = 1, .via = 1, .hops = 1, .seq = 1, .heard_at = 0 };
    try n.forwarding_table.setRoute(1, parent.mq_idx, 1);
    const p = n.power.?;

    try n.sendToRoot("x", MessageQueue.PRIORITY_LOW);
    try std.testing.expect(try n.requestWrite());
    const wait = p.frameMs(TestNet.wire_len) + p.backoffMs();

    n.queueAnnouncement(.{ .root = 1, .seq = 1, .hops = 1 }, 0);
    try std.testing.expect(!try n.requestWrite());
    TestClock.time = wait - 1;
    try std.testing.expect(!try n.requestWrite());
    TestClock.time = wait;
    try std.testing.expect(try n.requestWrite());

    n.handle_network_packet(.{ .from = 1, .to = 2, .origin = 1, .dest = 2, .hops = 0, .nesn = !parent.sn });
    try std.testing.expect(n.outgoing_packets.allEmpty());

    try n.sendToRoot("y", MessageQueue.PRIORITY_LOW);
    TestClock.time += 1;
    try std.testing.expect(try n.requestWrite());
    n.queueAnnouncement(.{ .root = 1, .seq = 1, .hops = 1 }, 0);
    try std.testing.expect(!try n.requestWrite());

    n.handle_network_packet(.{ .from = 1, .to = 2, .origin = 1, .dest = 2, .hops = 0, .nesn = !parent.sn });
    try std.testing.expect(n.ack_wait_until == null);
    try std.testing.expect(try n.requestWrite());
}

test "a neighbor overheard sending to someone else is left alone until its ack is back" {
    TestClock.time = 0;

    var n = TestClock.node(3);
    n.power = .{ .period_ms = 60_000, .radio = .{ .spreading_factor = 7 } };
    n.own_window = 1000;
    n.own_window_set = true;
    const parent = try n.registerNeighbor(2, 0);
    n.root = .{ .addr = 1, .via = 2, .hops = 2, .seq = 1, .heard_at = 0 };
    try n.forwarding_table.setRoute(1, parent.mq_idx, 2);
    try n.sendToRoot("x", MessageQueue.PRIORITY_LOW);
    const p = n.power.?;

    var overheard = NetworkPacket{ .from = 2, .to = 1, .origin = 2, .dest = 1, .len = 1, .period = 600, .wake_phase = NetworkPacket.wakePhase(30_000, 60_000), .hops = 1 };
    overheard.payload[0] = 'y';
    n.handle_network_packet(overheard);

    try std.testing.expect(!try n.requestWrite());
    TestClock.time = p.backoffMs() - 1;
    try std.testing.expect(!try n.requestWrite());
    TestClock.time = p.backoffMs();
    try std.testing.expect(try n.requestWrite());
    try std.testing.expect(parent.sent);
}

test "rooted sleepy nodes beacon right after their own window every few periods" {
    TestClock.time = 0;

    var a = TestClock.node(1);
    var b = TestClock.node(2);
    b.power = .{ .period_ms = 1000, .beacon_periods = 2, .radio = .{ .spreading_factor = 7 } };

    announcementFrom(&a, 1, 5, 0);
    try TestNet.transmit(&a, &.{&b});
    try std.testing.expectEqual(@as(?Address, 1), b.rootAddress());

    const p = b.power.?;
    var beacons: usize = 0;
    while (TestClock.time < 20_000) : (TestClock.time += 5) {
        if (b.idleFor() != 0) continue;
        while (try b.requestWrite()) {
            var probe = TestNet.node(99);
            TestNet.delivered = null;
            try TestNet.hear(&probe);
            const got = TestNet.delivered orelse continue;
            if (!got.broadcast or AppPacket.parse(got.body()).?.op != .im_a_root) continue;

            beacons += 1;
            const now = TestClock.time;
            const since = now -% b.ownWindowStart(now -% p.windowMs());
            try std.testing.expect(since >= p.windowMs() and since <= p.windowMs() + p.baseGuardMs() + 5);
            try std.testing.expectEqual(@as(u8, 1), got.hops);
        }
    }

    try std.testing.expect(beacons >= 9 and beacons <= 10);
}

const Air = struct {
    const Frame = struct {
        bytes: [TX_BUFFER_SIZE]u8,
        len: usize,
        from: Address,
        at: u32,
    };

    nodes: []const *Yggdrasil,
    links: []const [2]Address,
    sample_ms: u32 = 0,
    frames: [64]Frame = undefined,
    num_frames: usize = 0,

    fn hears(air: *const Air, a: Address, b: Address) bool {
        for (air.links) |l| {
            if ((l[0] == a and l[1] == b) or (l[0] == b and l[1] == a)) return true;
        }
        return false;
    }

    fn deliver(ygg: *Yggdrasil, bytes: []const u8) void {
        ygg.handleFrame(bytes);
    }

    fn step(air: *Air) !void {
        const now = TestClock.time;

        var i: usize = 0;
        while (i < air.num_frames) {
            const frame = air.frames[i];
            if (!Yggdrasil.reached(now, frame.at)) {
                i += 1;
                continue;
            }
            for (air.nodes) |n| {
                if (n.address != frame.from and air.hears(frame.from, n.address) and n.idleFor() == 0)
                    deliver(n, frame.bytes[0..frame.len]);
            }
            air.num_frames -= 1;
            air.frames[i] = air.frames[air.num_frames];
        }

        if (air.sample_ms != 0) {
            for (air.nodes) |n| {
                if (n.is_root or (now +% @as(u32, n.address) * 7910) % air.sample_ms != 0) continue;
                n.sendToRoot("s", MessageQueue.PRIORITY_LOW) catch {};
            }
        }

        for (air.nodes) |n| {
            if (n.idleFor() != 0) continue;
            for (0..4) |_| {
                if (!try n.requestWrite()) break;
                if (air.num_frames >= air.frames.len) return error.AirFull;
                const airtime = if (n.power) |p| p.frameMs(TestNet.wire_len) else 0;
                const frame = &air.frames[air.num_frames];
                @memcpy(frame.bytes[0..TestNet.wire_len], TestNet.wire[0..TestNet.wire_len]);
                frame.len = TestNet.wire_len;
                frame.from = n.address;
                frame.at = now +% airtime;
                air.num_frames += 1;
            }
        }
    }

    fn runUntil(air: *Air, limit_ms: u32, done: *const fn () bool) !bool {
        while (TestClock.time < limit_ms) : (TestClock.time += 10) {
            try air.step();
            if (done()) return true;
        }
        return false;
    }
};

fn sleepyNode(addr: Address, period_ms: u32) Yggdrasil {
    var ygg = TestClock.node(addr);
    ygg.retransmit_timeout_ms = 3000;
    ygg.retransmit_jitter_ms = 1000;
    ygg.max_retries = 10;
    ygg.root_timeout_ms = 6 * period_ms;
    ygg.power = .{
        .period_ms = period_ms,
        .neighbor_timeout_ms = 30 * period_ms,
        .radio = .{ .spreading_factor = 7 },
    };
    return ygg;
}

const ChainRoot = struct {
    var got_from_far: bool = false;
    var far_addr: Address = 3;

    fn cb(packet: NetworkPacket) void {
        if (packet.origin == far_addr and packet.dest == 1 and std.mem.eql(u8, packet.body(), "far"))
            got_from_far = true;
    }
};

var chain_far: *Yggdrasil = undefined;
var chain_relay: *Yggdrasil = undefined;

fn chainJoined() bool {
    return chain_far.rootAddress() != null;
}

fn relayJoined() bool {
    return chain_relay.rootAddress() != null;
}

fn never() bool {
    return false;
}

fn chainDelivered() bool {
    return ChainRoot.got_from_far;
}

test "sleepy nodes join through a sleepy relay out of range of the root" {
    TestClock.time = 0;
    TestClock.lost = null;
    ChainRoot.got_from_far = false;
    ChainRoot.far_addr = 3;

    var root = TestClock.node(1);
    root.is_root = true;
    root.result_cb = ChainRoot.cb;
    root.power = .{ .period_ms = 0, .radio = .{ .spreading_factor = 7 } };

    var relay = sleepyNode(2, 60_000);
    var far = sleepyNode(3, 60_000);
    chain_relay = &relay;
    chain_far = &far;

    var air = Air{
        .nodes = &.{ &root, &relay },
        .links = &.{ .{ 1, 2 }, .{ 2, 3 } },
        .sample_ms = 60_000,
    };

    try std.testing.expect(try air.runUntil(5 * 60_000, relayJoined));
    _ = try air.runUntil(TestClock.time + 10 * 60_000, never);
    try std.testing.expectEqual(@as(?Address, 1), relay.rootAddress());

    air.nodes = &.{ &root, &relay, &far };
    try std.testing.expect(try air.runUntil(TestClock.time + 20 * 60_000, chainJoined));
    try std.testing.expectEqual(@as(?Address, 1), relay.rootAddress());
    try std.testing.expectEqual(@as(u8, 2), far.root.?.hops);
    try std.testing.expectEqual(@as(Address, 2), far.root.?.via);

    try far.sendToRoot("far", MessageQueue.PRIORITY_LOW);
    try std.testing.expect(try air.runUntil(TestClock.time + 5 * 60_000, chainDelivered));
}

var room_a: *Yggdrasil = undefined;
var room_b: *Yggdrasil = undefined;

fn roomJoined() bool {
    return room_a.rootAddress() != null and room_b.rootAddress() != null;
}

test "a full root refuses new children so they hop through an existing one" {
    TestClock.time = 0;
    TestClock.lost = null;
    ChainRoot.got_from_far = false;

    var root = TestClock.node(1);
    root.is_root = true;
    root.max_children = 1;
    root.result_cb = ChainRoot.cb;
    root.power = .{ .period_ms = 0, .root_beacon_ms = 20_000, .radio = .{ .spreading_factor = 7 } };

    var a = sleepyNode(2, 60_000);
    var b = sleepyNode(3, 60_000);
    room_a = &a;
    room_b = &b;

    var air = Air{
        .nodes = &.{ &root, &a, &b },
        .links = &.{ .{ 1, 2 }, .{ 1, 3 }, .{ 2, 3 } },
        .sample_ms = 60_000,
    };

    try std.testing.expect(try air.runUntil(30 * 60_000, roomJoined));
    _ = try air.runUntil(TestClock.time + 10 * 60_000, never);

    try std.testing.expectEqual(@as(usize, 1), root.forwarding_table.num_registered_output_map);
    try std.testing.expect(root.atCapacity());

    const near, const far = if (a.root.?.hops == 1) .{ &a, &b } else .{ &b, &a };
    try std.testing.expectEqual(@as(u8, 1), near.root.?.hops);
    try std.testing.expectEqual(@as(u8, 2), far.root.?.hops);
    try std.testing.expectEqual(near.address, far.root.?.via);
    try std.testing.expect(root.forwarding_table.neighborByAddr(near.address) != null);

    ChainRoot.far_addr = far.address;
    try far.sendToRoot("far", MessageQueue.PRIORITY_LOW);
    try std.testing.expect(try air.runUntil(TestClock.time + 5 * 60_000, chainDelivered));
}

test "traffic to the root follows the adopted parent over an overheard direct root" {
    TestClock.time = 0;

    var n = TestClock.node(3);
    const parent = try n.registerNeighbor(2, 0);
    n.root = .{ .addr = 1, .via = 2, .hops = 2, .seq = 1, .heard_at = 0 };
    try n.forwarding_table.setRoute(1, parent.mq_idx, 2);
    _ = try n.registerNeighbor(1, 1);

    try n.sendToRoot("x", MessageQueue.PRIORITY_LOW);
    try std.testing.expectEqual(@as(Address, 2), n.outgoing_packets.txBuffer(parent.mq_idx).?.to);
    try std.testing.expect(n.outgoing_packets.txBuffer(1) == null);
}

test "a full root ignores hellos and direct frames from new nodes" {
    TestClock.time = 0;

    var root = TestClock.node(1);
    root.is_root = true;
    root.max_children = 1;
    root.power = .{ .period_ms = 0 };
    var a = TestClock.node(2);
    var b = TestClock.node(3);

    try a.sayHello();
    try TestNet.hear(&root);
    try std.testing.expect(root.forwarding_table.neighborByAddr(2) != null);
    try std.testing.expect(root.atCapacity());

    try b.sayHello();
    try TestNet.hear(&root);
    try std.testing.expect(root.forwarding_table.neighborByAddr(3) == null);

    _ = try b.registerNeighbor(1, 0);
    try b.send(1, "x", MessageQueue.PRIORITY_LOW);
    TestNet.delivered = null;
    try TestNet.transmit(&b, &.{&root});
    try std.testing.expect(TestNet.delivered == null);
    try std.testing.expect(root.forwarding_table.neighborByAddr(3) == null);

    root.dropNeighbor(2);
    try std.testing.expect(!root.atCapacity());
    try b.sayHello();
    try TestNet.hear(&root);
    try std.testing.expect(root.forwarding_table.neighborByAddr(3) != null);
}

fn compactApp(celsius: f32, buf: *[AppPacket.CompactReadings.MAX_LEN + 1]u8) []const u8 {
    const r: AppPacket.CompactReadings = .{ .centi_celsius = AppPacket.CompactReadings.temperature(celsius) };
    var rec: [AppPacket.CompactReadings.MAX_LEN]u8 = undefined;
    const bytes = r.write(&rec);
    buf[0] = @backingInt(AppPacket.Opcode.compact_readings);
    @memcpy(buf[1..][0..bytes.len], bytes);
    return buf[0 .. 1 + bytes.len];
}

fn relayLine() !struct { leaf: Yggdrasil, relay: Yggdrasil, root: Yggdrasil } {
    var leaf = TestNet.node(1);
    var relay = TestNet.node(2);
    var root = TestNet.node(3);

    _ = try leaf.registerNeighbor(2, 0);
    _ = try relay.registerNeighbor(1, 0);
    _ = try relay.registerNeighbor(3, 1);
    _ = try root.registerNeighbor(2, 0);
    try leaf.forwarding_table.setRoute(3, 0, 2);
    try relay.forwarding_table.setRoute(3, 1, 1);
    return .{ .leaf = leaf, .relay = relay, .root = root };
}

fn drain(from: *Yggdrasil, listeners: []const *Yggdrasil) !void {
    for (0..4) |_| {
        if (!try from.requestWrite()) break;
        for (listeners) |listener| try TestNet.hear(listener);
        if (TestNet.delivered != null) return;
    }
    return error.NothingDelivered;
}

fn expectBatch(origins: []const Address) !void {
    const got = TestNet.delivered orelse return error.NothingDelivered;
    const app = AppPacket.parse(got.body()).?;
    try std.testing.expectEqual(AppPacket.Opcode.batched_readings, app.op);

    var batch = AppPacket.ReadingBatch{ .bytes = app.payload };
    for (origins) |origin| try std.testing.expectEqual(origin, batch.next().?.origin);
    try std.testing.expect(batch.next() == null);
    try std.testing.expectEqual(@as(usize, 0), batch.bytes.len);
}

test "a relay folds a forwarded reading into its own queued reading" {
    var net = try relayLine();
    var buf: [AppPacket.CompactReadings.MAX_LEN + 1]u8 = undefined;

    try net.relay.send(3, compactApp(20.0, &buf), MessageQueue.PRIORITY_LOW);
    try net.leaf.send(3, compactApp(21.0, &buf), MessageQueue.PRIORITY_LOW);
    try TestNet.transmit(&net.leaf, &.{&net.relay});

    TestNet.delivered = null;
    try drain(&net.relay, &.{ &net.leaf, &net.root });
    try expectBatch(&.{ 2, 1 });
}

test "a held but unsent reading takes the merge and keeps relay origin" {
    var net = try relayLine();
    var buf: [AppPacket.CompactReadings.MAX_LEN + 1]u8 = undefined;

    try net.leaf.send(3, compactApp(21.0, &buf), MessageQueue.PRIORITY_LOW);
    try TestNet.transmit(&net.leaf, &.{&net.relay});
    _ = net.relay.outgoing_packets.txBuffer(1);

    try net.relay.send(3, compactApp(20.0, &buf), MessageQueue.PRIORITY_LOW);

    TestNet.delivered = null;
    try drain(&net.relay, &.{ &net.leaf, &net.root });
    try expectBatch(&.{ 1, 2 });
    try std.testing.expectEqual(@as(Address, 2), TestNet.delivered.?.origin);
}

test "batches from deeper relays are flattened into one batch" {
    var net = try relayLine();
    var buf: [AppPacket.CompactReadings.MAX_LEN + 1]u8 = undefined;

    var batch = [_]u8{ @backingInt(AppPacket.Opcode.batched_readings), 9, 0x01, 0x00, 0x01, 8, 0x01, 0x00, 0x02 };
    try net.relay.send(3, compactApp(20.0, &buf), MessageQueue.PRIORITY_LOW);
    try net.leaf.send(3, &batch, MessageQueue.PRIORITY_LOW);
    try TestNet.transmit(&net.leaf, &.{&net.relay});

    TestNet.delivered = null;
    try drain(&net.relay, &.{ &net.leaf, &net.root });
    try expectBatch(&.{ 2, 9, 8 });
}

test "readings already on the air and non reading packets are never merged" {
    var net = try relayLine();
    var buf: [AppPacket.CompactReadings.MAX_LEN + 1]u8 = undefined;

    try net.relay.send(3, compactApp(20.0, &buf), MessageQueue.PRIORITY_LOW);
    try std.testing.expect(try net.relay.requestWrite());

    try net.leaf.send(3, compactApp(21.0, &buf), MessageQueue.PRIORITY_LOW);
    try TestNet.transmit(&net.leaf, &.{&net.relay});
    try net.relay.send(3, "raw", MessageQueue.PRIORITY_LOW);

    try std.testing.expectEqual(AppPacket.Opcode.compact_readings, AppPacket.parse(net.relay.outgoing_packets.queued(1, 0).?.body()).?.op);
    try std.testing.expect(net.relay.outgoing_packets.queued(1, 1) != null);
}

test "a full batch spills into a new packet" {
    var net = try relayLine();
    var buf: [AppPacket.CompactReadings.MAX_LEN + 1]u8 = undefined;

    var big: [NetworkPacket.MAX_PAYLOAD_SIZE]u8 = undefined;
    big[0] = @backingInt(AppPacket.Opcode.batched_readings);
    var n: usize = 1;
    while (n + 4 <= big.len) : (n += 4) {
        big[n] = 50;
        big[n + 1] = 0x01;
        big[n + 2] = 0;
        big[n + 3] = 0;
    }
    try net.relay.send(3, big[0..n], MessageQueue.PRIORITY_LOW);
    try net.relay.send(3, compactApp(20.0, &buf), MessageQueue.PRIORITY_LOW);

    try std.testing.expect(net.relay.outgoing_packets.queued(1, 1) != null);
}

test {
    _ = @import("lora.zig");
    _ = @import("power.zig");
    _ = @import("network_packet.zig");
    _ = @import("app_packet.zig");
    _ = @import("routing.zig");
    _ = @import("message_queue.zig");
    _ = @import("link_layer.zig");
}
