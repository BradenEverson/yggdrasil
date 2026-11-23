const std = @import("std");
const yggdrasil = @import("yggdrasil");
const node_config = @import("node_config");
const target = @import("target");

const hal = @import("hal.zig");
const Rylr = @import("drivers/rylr896.zig");
const bme688 = @import("drivers/bme688.zig");

comptime {
    _ = hal;
}

const board = switch (target.chip) {
    .f446 => @import("board/nucleo_f446re.zig"),
    .u073 => @import("board/u073cb.zig"),
};

const debug = board.debug_uart;
const lora_uart = board.lora_uart;
const sensor_i2c = board.sensor_i2c;
const BAUD_RATE = 115200;
const LORA_TX_SIZE = 256;
const LORA_LINE_SIZE = 32;
const YGG_RX_SIZE = yggdrasil.NetworkPacket.MAX_FRAME_LEN;
const MAX_WRITES_PER_PASS = 4;
const FAIL_RETRY_MS: u32 = 60_000;

const NETWORK_ID: u16 = 5;
const NODE_ADDR: yggdrasil.Address = node_config.node_addr;
const PERIOD_MS: u32 = node_config.period_ms;
const SAMPLE_MS: u32 = node_config.sample_ms;
const SAMPLE_INTERVAL_S: u16 = @intCast(SAMPLE_MS / 1000);
const SAMPLES_PER_SEND: usize = @max(PERIOD_MS / SAMPLE_MS, 1);
const MAX_SERIES: usize = @min(@max(2 * SAMPLES_PER_SEND, 4), 32);
const RADIO_BROADCAST_ADDR: u16 = 0;

const RADIO: yggdrasil.lora.Radio = .{
    .spreading_factor = node_config.sf,
    .bandwidth_hz = node_config.bw,
    .coding_rate = node_config.cr,
    .preamble = node_config.preamble,
    .uart_baud = BAUD_RATE,
};

const POWER: yggdrasil.Power = .{
    .period_ms = PERIOD_MS,
    .radio = RADIO,
    .radio_wake_ms = node_config.radio_wake_ms,
    .beacon_periods = node_config.beacon_periods,
    .neighbor_timeout_ms = 30 * PERIOD_MS,
};

comptime {
    if (PERIOD_MS % yggdrasil.power.PERIOD_UNIT_MS != 0 or PERIOD_MS == 0)
        @compileError("period_ms must be a nonzero multiple of 100");
    if (SAMPLE_MS == 0 or SAMPLE_MS % (yggdrasil.AppPacket.ReadingSeries.INTERVAL_UNIT_S * 1000) != 0 or
        SAMPLE_MS > @as(u32, yggdrasil.AppPacket.ReadingSeries.MAX_INTERVAL_S) * 1000)
        @compileError("sample_ms must be a nonzero multiple of 10000, at most 2550000");
}

const debug_config: hal.uart.Config = .{
    .baud = BAUD_RATE,
    .tx = board.debug_tx,
    .rx = board.debug_rx,
};

const lora_config: hal.uart.Config = .{
    .baud = BAUD_RATE,
    .tx = board.lora_tx,
    .rx = board.lora_rx,
};

const sensor_config: hal.i2c.Config = .{
    .scl = board.sensor_scl,
    .sda = board.sensor_sda,
    .speed = .standard,
};

const used_pins = [_]hal.gpio.Pin{
    board.debug_tx,
    board.debug_rx,
    board.lora_tx,
    board.lora_rx,
    board.sensor_scl,
    board.sensor_sda,
} ++ if (node_config.swd) board.swd_pins else [_]hal.gpio.Pin{};

var lora_rx: [LORA_LINE_SIZE]u8 = undefined;
var lora_tx: [LORA_TX_SIZE]u8 = undefined;
var ygg_rx: [YGG_RX_SIZE]u8 = undefined;

var lora: Rylr = undefined;
var ygg: yggdrasil.Yggdrasil = undefined;
var sensor: bme688.Bme688 = undefined;
var radio_awake = false;
var next_sample: u32 = 0;

var series: [MAX_SERIES]yggdrasil.AppPacket.CompactReadings = undefined;
var series_at: [MAX_SERIES]u32 = undefined;
var series_len: usize = 0;

fn log(comptime fmt: []const u8, args: anytype) void {
    if (!node_config.log) return;
    hal.uart.print(debug, fmt, args);
}

fn radioRead(buf: []u8) yggdrasil.YggdrasilError![]u8 {
    return lora.read(buf);
}

fn traceFrame(dir: []const u8, f: []const u8, len: usize) void {
    if (!node_config.trace or f.len < yggdrasil.NetworkPacket.BASE_HEADER_LEN) return;
    log("{s} {}>{} len={} f={x} t={}\r\n", .{ dir, f[1], f[2], len, f[0], hal.timer.millis() });
}

fn radioWrite(buf: []u8) yggdrasil.YggdrasilError!void {
    traceFrame("tx", buf, buf.len);
    lora.sendData(RADIO_BROADCAST_ADDR, buf) catch |e| {
        log("send failed: {s}\r\n", .{@errorName(e)});
        return error.WriteFailed;
    };
}

fn onPacket(packet: yggdrasil.NetworkPacket) void {
    const parsed = yggdrasil.AppPacket.parse(packet.body());
    const op = if (parsed) |packet_app| @tagName(packet_app.op) else "raw";
    log("rx {} via {} {s}\r\n", .{ packet.origin, packet.from, op });
}

fn onNeighborLost(addr: yggdrasil.Address) void {
    log("lost neighbor {}\r\n", .{addr});
}

var rng_state: u32 = 0;

fn random(max: u32) u32 {
    if (rng_state == 0) rng_state = (@as(u32, NODE_ADDR) *% 2654435761) ^ hal.timer.millis() | 1;
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 17;
    rng_state ^= rng_state << 5;
    return rng_state % (max + 1);
}

fn reached(now: u32, deadline: u32) bool {
    return @as(i32, @bitCast(now -% deadline)) >= 0;
}

fn fail(what: []const u8, err: anyerror) noreturn {
    log("{s} failed: {s}\r\n", .{ what, @errorName(err) });
    sleepRadio();
    quiesce();
    if (hal.rtc.ready) stopFor(FAIL_RETRY_MS);
    hal.reset();
}

fn quiesce() void {
    if (node_config.log) hal.uart.flush(debug);
    hal.uart.flush(lora_uart);
}

fn stopFor(ms: u32) void {
    hal.uart.detachPins(lora_config);
    hal.i2c.detachPins(sensor_config);
    hal.lowpower.stopFor(ms);
    hal.i2c.attachPins(sensor_i2c, sensor_config);
    hal.uart.attachPins(lora_uart, lora_config);
}

fn sleepRadio() void {
    if (!node_config.radio_sleep or !radio_awake) return;
    lora.sleep() catch |e| {
        log("radio sleep failed: {s}\r\n", .{@errorName(e)});
        return;
    };
    radio_awake = false;
}

var seen_frames: u32 = 0;

fn wakeRadio() void {
    if (radio_awake) return;
    const start = hal.timer.millis();
    const slot = ygg.rootAddress() != null and @as(i32, @bitCast(next_sample -% start)) <= @as(i32, @intCast(SAMPLE_MS / 2));
    const sampling = slot and blk: {
        sensor.start() catch |e| {
            log("measure failed: {s}\r\n", .{@errorName(e)});
            break :blk false;
        };
        break :blk true;
    };
    if (slot) next_sample = start +% SAMPLE_MS;
    lora.wake() catch |e| {
        log("radio wake failed: {s}\r\n", .{@errorName(e)});
        lora.reset();
        hal.timer.delayMs(1000);
        configureRadio() catch |err| fail("radio config", err);
    };
    radio_awake = true;
    const took = hal.timer.millis() -% start;
    const w = lora.last_wake;
    log("radio wake took {} ms attempts={} at={} params={} power={}\r\n", .{ took, w.attempts, w.at_ms, w.params_ms, w.power_ms });

    if (sampling) {
        if (sensor.finish()) |r| {
            record(r, start);
        } else |e| log("measure failed: {s}\r\n", .{@errorName(e)});
    }
    if (series_len >= SAMPLES_PER_SEND) flushSeries();
}

fn serviceRadio() void {
    ygg.readStream() catch |e| log("read failed: {s}\r\n", .{@errorName(e)});
    if (lora.received != seen_frames) {
        seen_frames = lora.received;
        const f = lora.last_rx[0..@min(lora.last_rx_len, Rylr.FRAME_PEEK)];
        traceFrame("rx", f, lora.last_rx_len);
        logSignal(f);
    }
}

fn logSignal(f: []const u8) void {
    if (f.len < yggdrasil.NetworkPacket.BASE_HEADER_LEN) {
        log("sig ? rssi={} snr={}\r\n", .{ lora.last_rssi, lora.last_snr });
        return;
    }
    log("sig {}>{} rssi={} snr={}\r\n", .{ f[1], f[2], lora.last_rssi, lora.last_snr });
}

fn configureRadio() Rylr.RylrError!void {
    while (hal.uart.tryReadByte(lora_uart)) |_| {}
    try lora.setNetwork(NETWORK_ID);
    try lora.setAddr(NODE_ADDR);
    try lora.setParameters(.{
        .spreading_factor = RADIO.spreading_factor,
        .bandwidth = Rylr.Bandwidth.fromHz(RADIO.bandwidth_hz),
        .coding_rate = RADIO.coding_rate,
        .preamble = RADIO.preamble,
    });
    try lora.setPower(node_config.tx_power);
}

pub fn app() void {
    hal.lowpower.parkUnusedPins(&used_pins);

    if (node_config.log) hal.uart.init(debug, debug_config);

    hal.timer.init(board.sysclk_hz);
    const clock_source = hal.rtc.init();
    log("rtc on {s}\r\n", .{@tagName(clock_source)});

    hal.i2c.init(sensor_i2c, sensor_config);

    sensor = bme688.Bme688.init(sensor_i2c, bme688.ADDR_HIGH, bme688.LOW_POWER) catch |e| fail("BME688 init", e);

    lora = .{
        .uart = lora_uart,
        .rx_buffer = &lora_rx,
        .tx_buffer = &lora_tx,
    };

    hal.uart.init(lora_uart, lora_config);

    lora.reset();
    hal.timer.delayMs(1000);
    while (hal.uart.tryReadByte(lora_uart)) |_| {}
    hal.uart.enableRxInterrupt(lora_uart);

    configureRadio() catch |e| fail("radio config", e);
    radio_awake = true;
    log("node {} sf{} period {} ms\r\n", .{ NODE_ADDR, RADIO.spreading_factor, PERIOD_MS });

    ygg = .{
        .read_bytes_fn = radioRead,
        .write_bytes_fn = radioWrite,
        .result_cb = onPacket,
        .address = NODE_ADDR,
        .clock = hal.timer.millis,
        .neighbor_lost_cb = onNeighborLost,
        .root_timeout_ms = 6 * PERIOD_MS,
        .max_retries = 10,
        .power = POWER,
        .topology_flooding = false,
        .topology_reporting = true,
        .outgoing_packets = .{ .slots = undefined, .tx_buffers = undefined },
    };
    for (0..yggdrasil.MessageQueue.MAX_NEIGHBORS) |slot| ygg.outgoing_packets.clearSlot(slot);
    ygg.buffer = &ygg_rx;

    log("window {} ms\r\n", .{POWER.windowMs()});

    var known_root: ?yggdrasil.Address = null;
    next_sample = hal.timer.millis() +% random(SAMPLE_MS);

    while (true) {
        const now = hal.timer.millis();

        const overdue = reached(now, next_sample +% SAMPLE_MS / 4);
        if (reached(now, next_sample) and (overdue or ygg.idleFor() != 0)) {
            next_sample +%= SAMPLE_MS;
            if (reached(now, next_sample)) next_sample = now +% SAMPLE_MS;
            sample();
        }

        if (ygg.idleFor() == 0) {
            wakeRadio();

            serviceRadio();

            var writes: usize = 0;
            while (writes < MAX_WRITES_PER_PASS) : (writes += 1) {
                const wrote = ygg.requestWrite() catch false;
                if (!wrote) break;
            }

            const current_root = ygg.rootAddress();
            if (current_root != known_root) {
                known_root = current_root;
                if (ygg.root) |r|
                    log("root {} via {} hops={}\r\n", .{ r.addr, r.via, r.hops })
                else
                    log("root lost\r\n", .{});
            }

            if (ygg.idleFor() == 0) hal.lowpower.idle();
            continue;
        }

        serviceRadio();

        const idle = ygg.idleFor();
        if (idle == 0) continue;

        if (radio_awake and idle < POWER.radio_wake_ms) {
            hal.lowpower.idle();
            continue;
        }

        sleepRadio();
        if (lora.pending()) {
            serviceRadio();
            continue;
        }

        if (!node_config.radio_sleep) {
            hal.lowpower.idle();
            continue;
        }

        const until_sample = next_sample -% hal.timer.millis();
        const nap = @min(idle, until_sample);
        if (nap < hal.lowpower.MIN_STOP_MS) {
            hal.lowpower.idle();
            continue;
        }

        quiesce();
        stopFor(nap);
    }
}

fn sample() void {
    if (ygg.rootAddress() == null) return;
    const at = hal.timer.millis();
    const r = sensor.measure() catch |e| {
        log("measure failed: {s}\r\n", .{@errorName(e)});
        return;
    };
    record(r, at);
}

fn record(r: bme688.Reading, at: u32) void {
    if (series_len == MAX_SERIES) dropSamples(1);
    series[series_len] = compactReadings(r);
    series_at[series_len] = at;
    series_len += 1;
}

fn dropSamples(n: usize) void {
    std.mem.copyForwards(yggdrasil.AppPacket.CompactReadings, series[0 .. series_len - n], series[n..series_len]);
    std.mem.copyForwards(u32, series_at[0 .. series_len - n], series_at[n..series_len]);
    series_len -= n;
}

fn evenlySpaced(prev: u32, next: u32) bool {
    const gap = next -% prev;
    const off = if (gap > SAMPLE_MS) gap - SAMPLE_MS else SAMPLE_MS - gap;
    return off <= SAMPLE_MS / 4;
}

fn flushSeries() void {
    if (series_len == 0 or ygg.rootAddress() == null) return;
    const Series = yggdrasil.AppPacket.ReadingSeries;
    const now = hal.timer.millis();

    var buf: [yggdrasil.NetworkPacket.MAX_PAYLOAD_SIZE - 1]u8 = undefined;
    var n: usize = 0;
    var start: usize = 0;
    var records: usize = 0;
    while (start < series_len) {
        var end = start + 1;
        while (end < series_len and evenlySpaced(series_at[end - 1], series_at[end])) end += 1;
        const age_s: u16 = @intCast(@min((now -% series_at[end - 1]) / 1000, std.math.maxInt(u16)));
        const rec = Series.write(NODE_ADDR, SAMPLE_INTERVAL_S, age_s, series[start..end], buf[n..]) catch break;
        n += rec.len;
        records += 1;
        start = end;
    }
    if (start == 0) return;

    ygg.sendAppToRoot(.{ .op = .reading_series, .payload = buf[0..n] }, yggdrasil.MessageQueue.PRIORITY_LOW) catch |e| {
        log("send failed: {s}\r\n", .{@errorName(e)});
        return;
    };
    log("queued {} samples in {} records, {} bytes\r\n", .{ start, records, n });
    dropSamples(start);
}

fn compactReadings(r: bme688.Reading) yggdrasil.AppPacket.CompactReadings {
    const C = yggdrasil.AppPacket.CompactReadings;
    return .{
        .centi_celsius = C.temperature(r.temperature_c),
        .deci_hpa = C.pressure(r.pressure_pa),
        .centi_pct = C.humidity(r.humidity_pct),
    };
}
