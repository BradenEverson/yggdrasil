const std = @import("std");
const hal = @import("hal.zig");
const Rylr = @import("drivers/rylr896.zig");
const bme688 = @import("drivers/bme688.zig");
const ina260 = @import("drivers/ina260.zig");

const debug: hal.uart.Uart = .usart2;
const lora_uart: hal.uart.Uart = .usart1;
const BAUD_RATE = 115200;
const BUF_SIZE = 256;

const NETWORK_ID: u16 = 5;
const NODE_ADDR: u16 = 1;
const TARGET_ADDR: u16 = 2;
const SAMPLE_PERIOD_MS: u32 = 30_000;

var lora_rx: [BUF_SIZE]u8 = undefined;
var lora_tx: [BUF_SIZE]u8 = undefined;

fn fail(what: []const u8, err: anyerror) noreturn {
    hal.uart.print(debug, "{s} failed: {s}\r\n", .{ what, @errorName(err) });
    while (true) {}
}

fn clamp(x: f32, lo: f32, hi: f32) f32 {
    if (x < lo) return lo;
    if (x > hi) return hi;
    return x;
}

fn encode(buf: *[12]u8, r: bme688.Reading, power_mw: u16) void {
    const gas_ok = r.gas_valid and r.heater_stable;

    const pressure: u16 = @intFromFloat(clamp(r.pressureHpa() * 10.0, 0, 65535));
    const temp: i16 = @intFromFloat(clamp(r.temperatureF() * 100.0, -32768, 32767));
    const hum: u16 = @intFromFloat(clamp(r.humidity_pct * 100.0, 0, 10000));
    const gas: u32 = if (gas_ok)
        @intFromFloat(clamp(r.gas_resistance_ohm, 0, 4_294_967_040))
    else
        0;

    std.mem.writeInt(u16, buf[0..2], pressure, .big);
    std.mem.writeInt(i16, buf[2..4], temp, .big);
    std.mem.writeInt(u16, buf[4..6], hum, .big);
    std.mem.writeInt(u32, buf[6..10], gas, .big);
    std.mem.writeInt(u16, buf[10..12], power_mw, .big);
}

const CPACR: *volatile u32 = @ptrFromInt(0xE000_ED88);

export fn run() void {
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

    hal.uart.init(lora_uart, .{
        .baud = BAUD_RATE,
        .tx = .{ .port = .a, .num = 9 },
        .rx = .{ .port = .a, .num = 10 },
    });

    var lora: Rylr = .{
        .uart = lora_uart,
        .rx_buffer = &lora_rx,
        .tx_buffer = &lora_tx,
    };

    hal.uart.writeStr(debug, "UART ready\r\n");

    lora.reset();
    hal.timer.delayMs(1000);
    while (hal.uart.tryReadByte(lora_uart)) |_| {}

    hal.uart.print(debug, "Configuring network id={} addr={}\r\n", .{ NETWORK_ID, NODE_ADDR });

    lora.setNetwork(NETWORK_ID) catch |e| fail("setNetwork", e);
    hal.timer.delayMs(200);

    lora.setAddr(NODE_ADDR) catch |e| fail("setAddr", e);
    hal.timer.delayMs(5000);

    hal.uart.print(debug, "Node {} ready, sending to {}\r\n", .{ NODE_ADDR, TARGET_ADDR });

    while (true) {
        if (sensor.measure()) |r| {
            const power_mw: u16 = if (power.readPowerMw()) |mw|
                @intCast(@min(mw, std.math.maxInt(u16)))
            else |e| blk: {
                hal.uart.print(debug, "read power failed: {s}\r\n", .{@errorName(e)});
                break :blk 0;
            };

            var msg: [12]u8 = undefined;
            encode(&msg, r, power_mw);

            lora.sendData(TARGET_ADDR, &msg) catch |e| {
                hal.uart.print(debug, "send data failed: {s}\r\n", .{@errorName(e)});
            };

            hal.timer.delayMs(SAMPLE_PERIOD_MS);
        } else |e| {
            hal.uart.print(debug, "measure failed: {s}\r\n", .{@errorName(e)});
            hal.timer.delayMs(1000);
        }
    }
}
