const std = @import("std");
const gpio = @import("gpio.zig");
const rcc = @import("rcc.zig");
const RxRing = @import("../common/rx_ring.zig").RxRing;

pub const Uart = enum { usart1, usart2, usart3, usart4 };

const Signal = enum { tx, rx };

const PinOption = struct { uart: Uart, signal: Signal, port: gpio.Port, pin: u4, af: u4 };

const pin_options = [_]PinOption{
    .{ .uart = .usart1, .signal = .tx, .port = .a, .pin = 9, .af = 7 },
    .{ .uart = .usart1, .signal = .tx, .port = .b, .pin = 6, .af = 7 },
    .{ .uart = .usart1, .signal = .rx, .port = .a, .pin = 10, .af = 7 },
    .{ .uart = .usart1, .signal = .rx, .port = .b, .pin = 7, .af = 7 },
    .{ .uart = .usart2, .signal = .tx, .port = .a, .pin = 2, .af = 7 },
    .{ .uart = .usart2, .signal = .rx, .port = .a, .pin = 3, .af = 7 },
    .{ .uart = .usart2, .signal = .rx, .port = .a, .pin = 15, .af = 3 },
    .{ .uart = .usart3, .signal = .tx, .port = .a, .pin = 5, .af = 7 },
    .{ .uart = .usart3, .signal = .tx, .port = .b, .pin = 8, .af = 7 },
    .{ .uart = .usart3, .signal = .tx, .port = .b, .pin = 10, .af = 7 },
    .{ .uart = .usart3, .signal = .tx, .port = .c, .pin = 4, .af = 7 },
    .{ .uart = .usart3, .signal = .tx, .port = .c, .pin = 10, .af = 7 },
    .{ .uart = .usart3, .signal = .rx, .port = .a, .pin = 7, .af = 7 },
    .{ .uart = .usart3, .signal = .rx, .port = .b, .pin = 9, .af = 7 },
    .{ .uart = .usart3, .signal = .rx, .port = .b, .pin = 11, .af = 7 },
    .{ .uart = .usart3, .signal = .rx, .port = .c, .pin = 5, .af = 7 },
    .{ .uart = .usart3, .signal = .rx, .port = .c, .pin = 11, .af = 7 },
    .{ .uart = .usart4, .signal = .tx, .port = .a, .pin = 0, .af = 8 },
    .{ .uart = .usart4, .signal = .tx, .port = .c, .pin = 10, .af = 8 },
    .{ .uart = .usart4, .signal = .rx, .port = .a, .pin = 1, .af = 8 },
    .{ .uart = .usart4, .signal = .rx, .port = .c, .pin = 11, .af = 8 },
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
        .usart1 => 0x4001_3800,
        .usart2 => 0x4000_4400,
        .usart3 => 0x4000_4800,
        .usart4 => 0x4000_4C00,
    };
}

fn enableClock(uart: Uart) void {
    switch (uart) {
        .usart1 => rcc.apbenr2.* |= 1 << 14,
        .usart2 => rcc.apbenr1.* |= 1 << 17,
        .usart3 => rcc.apbenr1.* |= 1 << 18,
        .usart4 => rcc.apbenr1.* |= 1 << 19,
    }
}

const cr1 = 0x00;
const brr = 0x0C;
const isr = 0x1C;
const icr = 0x20;
const rdr = 0x24;
const tdr = 0x28;

const CR1_UE: u32 = 1 << 0;
const CR1_RE: u32 = 1 << 2;
const CR1_TE: u32 = 1 << 3;
const CR1_RXNEIE: u32 = 1 << 5;

const ISR_PE: u32 = 1 << 0;
const ISR_FE: u32 = 1 << 1;
const ISR_NE: u32 = 1 << 2;
const ISR_ORE: u32 = 1 << 3;
const ISR_RXNE: u32 = 1 << 5;
const ISR_TC: u32 = 1 << 6;
const ISR_TXE: u32 = 1 << 7;
const ISR_ERRORS: u32 = ISR_PE | ISR_FE | ISR_NE | ISR_ORE;

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
    attachPins(uart, config);

    var cr1_bits: u32 = CR1_UE;
    if (config.tx != null) cr1_bits |= CR1_TE;
    if (config.rx != null) cr1_bits |= CR1_RE;

    reg(uart, cr1).* = 0;
    reg(uart, brr).* = computeBRR(config.baud);
    reg(uart, cr1).* = cr1_bits;
}

pub fn attachPins(comptime uart: Uart, comptime config: Config) void {
    if (config.tx) |tx| {
        gpio.enable(tx.port);
        gpio.alternate(tx.port, tx.num, comptime afFor(uart, .tx, tx));
    }
    if (config.rx) |rx| {
        gpio.enable(rx.port);
        gpio.alternate(rx.port, rx.num, comptime afFor(uart, .rx, rx));
        gpio.pullUp(rx.port, rx.num);
    }
}

pub fn detachPins(comptime config: Config) void {
    if (config.tx) |tx| gpio.analog(tx);
    if (config.rx) |rx| gpio.analog(rx);
}

pub fn writeByte(uart: Uart, byte: u8) void {
    while ((reg(uart, isr).* & ISR_TXE) == 0) {}
    reg(uart, tdr).* = byte;
}

pub fn readByte(uart: Uart) u8 {
    while (true) {
        if (tryReadByte(uart)) |byte| return byte;
    }
}

pub fn tryReadByte(uart: Uart) ?u8 {
    if (ringFor(uart)) |ring| {
        if (@atomicLoad(bool, &ring.enabled, .acquire)) return ring.pop();
    }

    const status = reg(uart, isr).*;
    if (status & ISR_ERRORS != 0) reg(uart, icr).* = ISR_ERRORS;
    if ((status & ISR_RXNE) == 0) return null;
    return @truncate(reg(uart, rdr).*);
}

const irq_uarts = [_]Uart{.usart1};

var rings: [irq_uarts.len]RxRing = @splat(.{});

fn ringFor(uart: Uart) ?*RxRing {
    inline for (irq_uarts, 0..) |u, i| {
        if (u == uart) return &rings[i];
    }
    return null;
}

const NVIC_ISER0: *volatile u32 = @ptrFromInt(0xE000_E100);

fn irqNumber(uart: Uart) u5 {
    return switch (uart) {
        .usart1 => 27,
        .usart2 => 28,
        .usart3 => 29,
        .usart4 => 30,
    };
}

pub fn enableRxInterrupt(comptime uart: Uart) void {
    const ring = comptime_ring: {
        inline for (irq_uarts, 0..) |u, i| {
            if (u == uart) break :comptime_ring &rings[i];
        }
        @compileError(@tagName(uart) ++ " has no RX ring/IRQ handler -- add it to irq_uarts");
    };
    reg(uart, icr).* = ISR_ERRORS;
    while ((reg(uart, isr).* & ISR_RXNE) != 0) _ = reg(uart, rdr).*;
    @atomicStore(bool, &ring.enabled, true, .release);

    reg(uart, cr1).* |= CR1_RXNEIE;

    NVIC_ISER0.* = @as(u32, 1) << irqNumber(uart);
}

pub fn droppedBytes(uart: Uart) u32 {
    const ring = ringFor(uart) orelse return 0;
    return @atomicLoad(u32, &ring.dropped, .monotonic);
}

fn handleRx(comptime uart: Uart) void {
    const status = reg(uart, isr).*;
    if (status & ISR_ERRORS != 0) reg(uart, icr).* = ISR_ERRORS;
    if (status & ISR_RXNE != 0) ringFor(uart).?.push(@truncate(reg(uart, rdr).*));
}

export fn USART1_IRQHandler() void {
    handleRx(.usart1);
}

pub fn flush(uart: Uart) void {
    while ((reg(uart, isr).* & ISR_TC) == 0) {}
}

pub fn writeStr(uart: Uart, str: []const u8) void {
    for (str) |c| writeByte(uart, c);
}
