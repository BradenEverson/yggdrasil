//! UARRRRRRT

const std = @import("std");
const gpio = @import("gpio.zig");
const rcc = @import("rcc.zig");

pub const Uart = enum { usart1, usart2, usart3, uart4, uart5, usart6 };

const Signal = enum { tx, rx };

const PinOption = struct { uart: Uart, signal: Signal, port: gpio.Port, pin: u4, af: u4 };

const pin_options = [_]PinOption{
    // USART1 (AF7)
    .{ .uart = .usart1, .signal = .tx, .port = .a, .pin = 9, .af = 7 },
    .{ .uart = .usart1, .signal = .tx, .port = .b, .pin = 6, .af = 7 },
    .{ .uart = .usart1, .signal = .rx, .port = .a, .pin = 10, .af = 7 },
    .{ .uart = .usart1, .signal = .rx, .port = .b, .pin = 7, .af = 7 },
    // USART2 (AF7)
    .{ .uart = .usart2, .signal = .tx, .port = .a, .pin = 2, .af = 7 },
    .{ .uart = .usart2, .signal = .tx, .port = .d, .pin = 5, .af = 7 },
    .{ .uart = .usart2, .signal = .rx, .port = .a, .pin = 3, .af = 7 },
    .{ .uart = .usart2, .signal = .rx, .port = .d, .pin = 6, .af = 7 },
    // USART3 (AF7)
    .{ .uart = .usart3, .signal = .tx, .port = .b, .pin = 10, .af = 7 },
    .{ .uart = .usart3, .signal = .tx, .port = .c, .pin = 10, .af = 7 },
    .{ .uart = .usart3, .signal = .tx, .port = .d, .pin = 8, .af = 7 },
    .{ .uart = .usart3, .signal = .rx, .port = .b, .pin = 11, .af = 7 },
    .{ .uart = .usart3, .signal = .rx, .port = .c, .pin = 11, .af = 7 },
    .{ .uart = .usart3, .signal = .rx, .port = .d, .pin = 9, .af = 7 },
    // UART4 (AF8)
    .{ .uart = .uart4, .signal = .tx, .port = .a, .pin = 0, .af = 8 },
    .{ .uart = .uart4, .signal = .tx, .port = .c, .pin = 10, .af = 8 },
    .{ .uart = .uart4, .signal = .rx, .port = .a, .pin = 1, .af = 8 },
    .{ .uart = .uart4, .signal = .rx, .port = .c, .pin = 11, .af = 8 },
    // UART5 (AF8)
    .{ .uart = .uart5, .signal = .tx, .port = .c, .pin = 12, .af = 8 },
    .{ .uart = .uart5, .signal = .rx, .port = .d, .pin = 2, .af = 8 },
    // USART6 (AF8)
    .{ .uart = .usart6, .signal = .tx, .port = .c, .pin = 6, .af = 8 },
    .{ .uart = .usart6, .signal = .tx, .port = .a, .pin = 11, .af = 8 },
    .{ .uart = .usart6, .signal = .rx, .port = .c, .pin = 7, .af = 8 },
    .{ .uart = .usart6, .signal = .rx, .port = .a, .pin = 12, .af = 8 },
};

var pb: [64]u8 = undefined;

pub fn print(uart: Uart, comptime fmt: []const u8, args: anytype) void {
    const stuff = std.mem.print(pb[0..], fmt, args) catch unreachable;
    writeStr(uart, stuff);
}

fn afFor(comptime uart: Uart, comptime signal: Signal, comptime pin: gpio.Pin) u4 {
    for (pin_options) |o| {
        if (o.uart == uart and o.signal == signal and o.port == pin.port and o.pin == pin.num)
            return o.af;
    }
    @compileError(std.fmt.comptimePrint(
        "P{s}{d} cannot be {s} for {s} -- check the pin_options table / datasheet",
        .{ @tagName(pin.port), pin.num, @tagName(signal), @tagName(uart) },
    ));
}

fn baseAddr(uart: Uart) u32 {
    return switch (uart) {
        .usart1 => 0x4001_1000,
        .usart2 => 0x4000_4400,
        .usart3 => 0x4000_4800,
        .uart4 => 0x4000_4C00,
        .uart5 => 0x4000_5000,
        .usart6 => 0x4001_1400,
    };
}

fn enableClock(uart: Uart) void {
    switch (uart) {
        .usart1 => rcc.apb2enr.* |= 1 << 4,
        .usart6 => rcc.apb2enr.* |= 1 << 5,
        .usart2 => rcc.apb1enr.* |= 1 << 17,
        .usart3 => rcc.apb1enr.* |= 1 << 18,
        .uart4 => rcc.apb1enr.* |= 1 << 19,
        .uart5 => rcc.apb1enr.* |= 1 << 20,
    }
}

const sr = 0x00;
const dr = 0x04;
const brr = 0x08;
const cr1 = 0x0C;

fn reg(uart: Uart, offset: u32) *volatile u32 {
    return @ptrFromInt(baseAddr(uart) + offset);
}

const pclk: u32 = 16_000_000;

fn computeBRR(baud: u32) u32 {
    return (pclk + baud / 2) / baud;
}

pub const Config = struct {
    baud: u32 = 115200,
    tx: ?gpio.Pin = null,
    rx: ?gpio.Pin = null,
};

pub fn init(comptime uart: Uart, comptime config: Config) void {
    comptime if (config.tx == null and config.rx == null)
        @compileError("uart.init needs at least one of .tx / .rx");

    enableClock(uart);

    var cr1_bits: u32 = 0x2000;
    if (config.tx) |tx| {
        gpio.enable(tx.port);
        gpio.alternate(tx.port, tx.num, comptime afFor(uart, .tx, tx));
        cr1_bits |= 0x0008;
    }
    if (config.rx) |rx| {
        gpio.enable(rx.port);
        gpio.alternate(rx.port, rx.num, comptime afFor(uart, .rx, rx));
        gpio.pullUp(rx.port, rx.num);
        cr1_bits |= 0x0004;
    }

    reg(uart, brr).* = computeBRR(config.baud);
    reg(uart, cr1).* = cr1_bits;
}

pub fn writeByte(uart: Uart, byte: u8) void {
    while ((reg(uart, sr).* & 0x0080) == 0) {}
    reg(uart, dr).* = byte;
}

pub fn readByte(uart: Uart) u8 {
    while ((reg(uart, sr).* & 0x0020) == 0) {}
    return @truncate(reg(uart, dr).*);
}

pub fn tryReadByte(uart: Uart) ?u8 {
    if ((reg(uart, sr).* & 0x0020) == 0) return null;
    return @truncate(reg(uart, dr).*);
}

pub fn writeStr(uart: Uart, str: []const u8) void {
    for (str) |c| writeByte(uart, c);
}
