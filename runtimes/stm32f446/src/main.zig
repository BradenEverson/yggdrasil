const std = @import("std");
const yggdrasil = @import("yggdrasil");
const node_config = @import("node_config");

const hal = @import("hal.zig");
const Rylr = @import("drivers/rylr896.zig");
const bme688 = @import("drivers/bme688.zig");
const ina260 = @import("drivers/ina260.zig");

const debug: hal.uart.Uart = .usart2;
const lora_uart: hal.uart.Uart = .usart1;
const BAUD_RATE = 115200;
const LORA_TX_SIZE = 256;
const LORA_LINE_SIZE = 32;
const YGG_RX_SIZE = 64;

const NETWORK_ID: u16 = 5;
const NODE_ADDR: u16 = node_config.node_addr;
const SAMPLE_PERIOD_MS: u32 = 30_000;
const ROOT_TIMEOUT_MS: u32 = 105_000;
const HELLO_PERIOD_MS: u32 = 10_000;
const HELLO_JITTER_MS: u32 = 2_000;
const TX_JITTER_MS: u32 = 300;
const RETRANSMIT_TIMEOUT_MS: u32 = 4_000;
const RETRANSMIT_JITTER_MS: u32 = 1_500;
const RADIO_BROADCAST_ADDR: u16 = 0;

var lora_rx: [LORA_LINE_SIZE]u8 = undefined;
var lora_tx: [LORA_TX_SIZE]u8 = undefined;
var ygg_rx: [YGG_RX_SIZE]u8 = undefined;

var lora: Rylr = undefined;
var ygg: yggdrasil.Yggdrasil = undefined;

fn radioRead(buf: []u8) yggdrasil.YggdrasilError![]u8 {
    return lora.read(buf);
}

fn radioWrite(buf: []u8) yggdrasil.YggdrasilError!void {
    lora.sendData(RADIO_BROADCAST_ADDR, buf) catch |e| {
        hal.uart.print(debug, "radio send failed: {s}\r\n", .{@errorName(e)});
        return error.WriteFailed;
    };
}

fn onPacket(packet: yggdrasil.NetworkPacket) void {
    const parsed = yggdrasil.AppPacket.parse(packet.body());
    const op = if (parsed) |packet_app| @tagName(packet_app.op) else "raw";
    hal.uart.print(debug, "rx {} via {} {s} len={} ttl={}\r\n", .{ packet.origin, packet.from, op, packet.len, packet.ttl });
}

fn onNeighborLost(addr: u16) void {
    hal.uart.print(debug, "lost neighbor {}\r\n", .{addr});
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
    hal.uart.print(debug, "{s} failed: {s}\r\n", .{ what, @errorName(err) });
    while (true) {}
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

fn app() void {
    hal.uart.init(debug, .{
        .baud = BAUD_RATE,
        .tx = .{ .port = .a, .num = 2 },
        .rx = .{ .port = .a, .num = 3 },
    });

    hal.timer.init(16_000_000);

    hal.i2c.init(.i2c1, .{
        .scl = .{ .port = .b, .num = 8 },
        .sda = .{ .port = .b, .num = 9 },
        .speed = .standard,
    });

    var sensor = bme688.Bme688.init(.i2c1, bme688.ADDR_HIGH, .{}) catch |e| fail("BME688 init", e);
    const power = ina260.Ina260.init(.i2c1, ina260.ADDR_DEFAULT, .x16) catch |e| fail("INA260 init", e);

    hal.uart.writeStr(debug, "Restarting LoRA Module\r\n");

    hal.uart.writeStr(debug, "Let's Mesh This Network\r\n");

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

    hal.uart.writeStr(debug, "UART ready\r\n");

    lora.reset();
    hal.timer.delayMs(1000);
    while (hal.uart.tryReadByte(lora_uart)) |_| {}

    hal.uart.enableRxInterrupt(lora_uart);

    hal.uart.print(debug, "Configuring network id={} addr={}\r\n", .{ NETWORK_ID, NODE_ADDR });

    lora.setNetwork(NETWORK_ID) catch |e| fail("setNetwork", e);
    hal.timer.delayMs(200);

    lora.setAddr(NODE_ADDR) catch |e| fail("setAddr", e);
    hal.timer.delayMs(5000);

    ygg = .{
        .read_bytes_fn = radioRead,
        .write_bytes_fn = radioWrite,
        .result_cb = onPacket,
        .address = NODE_ADDR,
        .clock = hal.timer.millis,
        .neighbor_lost_cb = onNeighborLost,
        .retransmit_timeout_ms = RETRANSMIT_TIMEOUT_MS,
        .retransmit_jitter_ms = RETRANSMIT_JITTER_MS,
        .root_timeout_ms = ROOT_TIMEOUT_MS,
        .outgoing_packets = .{ .slots = undefined, .tx_buffers = undefined },
    };
    for (0..yggdrasil.MessageQueue.MAX_NEIGHBORS) |slot| ygg.outgoing_packets.clearSlot(slot);
    ygg.buffer = &ygg_rx;

    hal.uart.print(debug, "Node {} ready\r\n", .{NODE_ADDR});

    var known_root: ?u16 = null;
    var next_hello: u32 = hal.timer.millis() +% random(HELLO_JITTER_MS);
    var next_write: u32 = hal.timer.millis();
    var next_sample: u32 = hal.timer.millis();

    while (true) {
        ygg.readStream() catch |e| {
            hal.uart.print(debug, "read failed: {s}\r\n", .{@errorName(e)});
        };

        const now = hal.timer.millis();

        if (reached(now, next_write)) {
            _ = ygg.requestWrite() catch {};
            next_write = hal.timer.millis() +% random(TX_JITTER_MS);
        }

        const current_root = ygg.rootAddress();
        if (current_root != known_root) {
            known_root = current_root;
            if (ygg.root) |root|
                hal.uart.print(debug, "root {} via {} hops={}\r\n", .{ root.addr, root.via, root.hops })
            else
                hal.uart.writeStr(debug, "root lost\r\n");
        }

        if (current_root == null and reached(now, next_hello)) {
            ygg.sayHello() catch {};
            next_hello = hal.timer.millis() +% HELLO_PERIOD_MS +% random(HELLO_JITTER_MS);
        }

        if (reached(now, next_sample)) {
            next_sample = now +% SAMPLE_PERIOD_MS;
            sample(&ygg, &sensor, &power);
        }
    }
}

fn sample(node: *yggdrasil.Yggdrasil, sensor: *bme688.Bme688, power: *const ina260.Ina260) void {
    const r = sensor.measure() catch |e| {
        hal.uart.print(debug, "measure failed: {s}\r\n", .{@errorName(e)});
        return;
    };

    const power_mw: u16 = if (power.readPowerMw()) |mw|
        @intCast(@min(mw, std.math.maxInt(u16)))
    else |e| blk: {
        hal.uart.print(debug, "read power failed: {s}\r\n", .{@errorName(e)});
        break :blk 0;
    };

    var readings_buf: [yggdrasil.NetworkPacket.MAX_PAYLOAD_SIZE - 1]u8 = undefined;
    var readings = yggdrasil.AppPacket.SensorReadingWriter{ .buf = &readings_buf };

    addReadings(&readings, r, power_mw) catch |e| {
        hal.uart.print(debug, "encode failed: {s}\r\n", .{@errorName(e)});
        return;
    };

    const packet: yggdrasil.AppPacket = .{ .op = .sensor_readings, .payload = readings.written() };

    node.sendAppToRoot(packet, yggdrasil.MessageQueue.PRIORITY_LOW) catch |e| {
        hal.uart.print(debug, "send failed: {s}\r\n", .{@errorName(e)});
    };
}

fn addReadings(readings: *yggdrasil.AppPacket.SensorReadingWriter, r: bme688.Reading, power_mw: u16) error{NoSpaceLeft}!void {
    try readings.add("t", .{ .float32 = r.temperatureF() });
    try readings.add("p", .{ .float32 = r.pressureHpa() });
    try readings.add("h", .{ .float32 = r.humidity_pct });

    if (r.gas_valid and r.heater_stable)
        try readings.add("g", .{ .float32 = r.gas_resistance_ohm });

    try readings.add("w", .{ .uint16 = power_mw });
}
