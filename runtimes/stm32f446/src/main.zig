const std = @import("std");
const yggdrasil = @import("yggdrasil");
const node_config = @import("node_config");

const hal = @import("hal.zig");
const Rylr = @import("drivers/rylr896.zig");
const bme688 = @import("drivers/bme688.zig");

const debug: hal.uart.Uart = .usart2;
const lora_uart: hal.uart.Uart = .usart1;
const BAUD_RATE = 115200;
const LORA_TX_SIZE = 256;
const LORA_LINE_SIZE = 32;
const YGG_RX_SIZE = 64;
const MAX_WRITES_PER_PASS = 4;
const FAIL_RETRY_MS: u32 = 60_000;

const NETWORK_ID: u16 = 5;
const NODE_ADDR: u16 = node_config.node_addr;
const PERIOD_MS: u32 = node_config.period_ms;
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
    .neighbor_timeout_ms = 30 * PERIOD_MS,
};

comptime {
    if (PERIOD_MS % yggdrasil.power.PERIOD_UNIT_MS != 0 or PERIOD_MS == 0)
        @compileError("period_ms must be a nonzero multiple of 100");
}

const used_pins = [_]hal.gpio.Pin{
    .{ .port = .a, .num = 2 },
    .{ .port = .a, .num = 3 },
    .{ .port = .a, .num = 9 },
    .{ .port = .a, .num = 10 },
    .{ .port = .b, .num = 8 },
    .{ .port = .b, .num = 9 },
} ++ if (node_config.swd) [_]hal.gpio.Pin{
    .{ .port = .a, .num = 13 },
    .{ .port = .a, .num = 14 },
} else [_]hal.gpio.Pin{};

var lora_rx: [LORA_LINE_SIZE]u8 = undefined;
var lora_tx: [LORA_TX_SIZE]u8 = undefined;
var ygg_rx: [YGG_RX_SIZE]u8 = undefined;

var lora: Rylr = undefined;
var ygg: yggdrasil.Yggdrasil = undefined;
var radio_awake = false;

fn log(comptime fmt: []const u8, args: anytype) void {
    if (!node_config.log) return;
    hal.uart.print(debug, fmt, args);
}

fn radioRead(buf: []u8) yggdrasil.YggdrasilError![]u8 {
    return lora.read(buf);
}

fn traceFrame(dir: []const u8, f: []const u8) void {
    if (!node_config.trace or f.len < yggdrasil.NetworkPacket.HEADER_LEN) return;
    const from = (@as(u16, f[1]) << 8) | f[2];
    const to = (@as(u16, f[3]) << 8) | f[4];
    log("{s} {}>{} len={} f={x} t={}\r\n", .{ dir, from, to, f[11], f[10], hal.timer.millis() });
}

fn radioWrite(buf: []u8) yggdrasil.YggdrasilError!void {
    traceFrame("tx", buf);
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

fn onNeighborLost(addr: u16) void {
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
    if (hal.rtc.ready) hal.lowpower.stopFor(FAIL_RETRY_MS);
    hal.reset();
}

const CPACR: *volatile u32 = @ptrFromInt(0xE000_ED88);

extern const _sidata: u8;
extern var _sdata: u8;
extern var _edata: u8;
extern var _sbss: u8;
extern var _ebss: u8;

fn initMemory() void {
    const data: [*]volatile u8 = @ptrCast(&_sdata);
    const load: [*]const u8 = @ptrCast(&_sidata);
    const data_len = @intFromPtr(&_edata) - @intFromPtr(&_sdata);
    for (0..data_len) |i| data[i] = load[i];

    const bss: [*]volatile u8 = @ptrCast(&_sbss);
    const bss_len = @intFromPtr(&_ebss) - @intFromPtr(&_sbss);
    for (0..bss_len) |i| bss[i] = 0;
}

export fn run() void {
    initMemory();
    CPACR.* |= 0xF << 20;
    asm volatile ("dsb\n isb");
    @call(.never_inline, app, .{});
}

fn quiesce() void {
    if (node_config.log) hal.uart.flush(debug);
    hal.uart.flush(lora_uart);
}

fn sleepRadio() void {
    if (!radio_awake) return;
    lora.sleep() catch |e| {
        log("radio sleep failed: {s}\r\n", .{@errorName(e)});
        return;
    };
    radio_awake = false;
}

var wake_reported = false;
var seen_frames: u32 = 0;

fn wakeRadio() void {
    if (radio_awake) return;
    const start = hal.timer.millis();
    lora.wake() catch |e| {
        log("radio wake failed: {s}\r\n", .{@errorName(e)});
        lora.reset();
        hal.timer.delayMs(1000);
        configureRadio() catch |err| fail("radio config", err);
    };
    radio_awake = true;
    const took = hal.timer.millis() -% start;
    if (!wake_reported or took > POWER.radio_wake_ms) {
        wake_reported = true;
        log("radio wake took {} ms\r\n", .{took});
    }
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

fn app() void {
    hal.lowpower.parkUnusedPins(&used_pins);

    if (node_config.log) {
        hal.uart.init(debug, .{
            .baud = BAUD_RATE,
            .tx = .{ .port = .a, .num = 2 },
            .rx = .{ .port = .a, .num = 3 },
        });
    }

    hal.timer.init(16_000_000);
    const clock_source = hal.rtc.init();
    log("rtc on {s}\r\n", .{@tagName(clock_source)});

    hal.i2c.init(.i2c1, .{
        .scl = .{ .port = .b, .num = 8 },
        .sda = .{ .port = .b, .num = 9 },
        .speed = .standard,
    });

    var sensor = bme688.Bme688.init(.i2c1, bme688.ADDR_HIGH, .{}) catch |e| fail("BME688 init", e);

    lora = .{
        .uart = lora_uart,
        .rx_buffer = &lora_rx,
        .tx_buffer = &lora_tx,
    };

    hal.uart.init(lora_uart, .{
        .baud = BAUD_RATE,
        .tx = .{ .port = .a, .num = 9 },
        .rx = .{ .port = .a, .num = 10 },
    });

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

    var known_root: ?u16 = null;
    var next_sample: u32 = hal.timer.millis() +% random(PERIOD_MS);

    while (true) {
        const now = hal.timer.millis();

        const overdue = reached(now, next_sample +% PERIOD_MS / 4);
        if (reached(now, next_sample) and (overdue or ygg.idleFor() != 0)) {
            next_sample +%= PERIOD_MS;
            if (reached(now, next_sample)) next_sample = now +% PERIOD_MS;
            sample(&ygg, &sensor);
        }

        if (ygg.idleFor() == 0) {
            wakeRadio();

            ygg.readStream() catch |e| log("read failed: {s}\r\n", .{@errorName(e)});
            if (lora.received != seen_frames) {
                seen_frames = lora.received;
                traceFrame("rx", lora.last_rx[0..@min(lora.last_rx_len, Rylr.FRAME_PEEK)]);
            }

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

        ygg.readStream() catch {};
        sleepRadio();

        const idle = ygg.idleFor();
        if (idle == 0) continue;

        const until_sample = next_sample -% hal.timer.millis();
        const nap = @min(idle, until_sample);
        if (nap < hal.lowpower.MIN_STOP_MS) {
            hal.lowpower.idle();
            continue;
        }

        quiesce();
        hal.lowpower.stopFor(nap);
    }
}

fn sample(node: *yggdrasil.Yggdrasil, sensor: *bme688.Bme688) void {
    if (node.rootAddress() == null) return;

    const r = sensor.measure() catch |e| {
        log("measure failed: {s}\r\n", .{@errorName(e)});
        return;
    };

    var readings_buf: [yggdrasil.NetworkPacket.MAX_PAYLOAD_SIZE - 1]u8 = undefined;
    var readings = yggdrasil.AppPacket.SensorReadingWriter{ .buf = &readings_buf };

    addReadings(&readings, r) catch |e| {
        log("encode failed: {s}\r\n", .{@errorName(e)});
        return;
    };

    const packet: yggdrasil.AppPacket = .{ .op = .sensor_readings, .payload = readings.written() };

    node.sendAppToRoot(packet, yggdrasil.MessageQueue.PRIORITY_LOW) catch |e| {
        log("send failed: {s}\r\n", .{@errorName(e)});
    };
}

fn addReadings(readings: *yggdrasil.AppPacket.SensorReadingWriter, r: bme688.Reading) error{NoSpaceLeft}!void {
    try readings.add("t", .{ .float32 = r.temperatureF() });
    try readings.add("p", .{ .float32 = r.pressureHpa() });
    try readings.add("h", .{ .float32 = r.humidity_pct });

    if (r.gas_valid and r.heater_stable)
        try readings.add("g", .{ .float32 = r.gas_resistance_ohm });
}
