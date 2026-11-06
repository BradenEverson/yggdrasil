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
    while (true) {
        if (tryReadByte(uart)) |byte| return byte;
    }
}

pub fn tryReadByte(uart: Uart) ?u8 {
    const ring = &rings[@intFromEnum(uart)];
    if (@atomicLoad(bool, &ring.enabled, .acquire)) return ring.pop();

    if ((reg(uart, sr).* & 0x0020) == 0) return null;
    return @truncate(reg(uart, dr).*);
}

const RX_RING_SIZE: u32 = 1024;

const RxRing = struct {
    buf: [RX_RING_SIZE]u8 = undefined,
    head: u32 = 0,
    tail: u32 = 0,
    enabled: bool = false,
    dropped: u32 = 0,

    fn push(ring: *RxRing, byte: u8) void {
        const head = @atomicLoad(u32, &ring.head, .monotonic);
        const tail = @atomicLoad(u32, &ring.tail, .acquire);
        if (head -% tail >= RX_RING_SIZE) {
            ring.dropped +%= 1;
            return;
        }
        ring.buf[head % RX_RING_SIZE] = byte;
        @atomicStore(u32, &ring.head, head +% 1, .release);
    }

    fn pop(ring: *RxRing) ?u8 {
        const tail = @atomicLoad(u32, &ring.tail, .monotonic);
        const head = @atomicLoad(u32, &ring.head, .acquire);
        if (head == tail) return null;
        const byte = ring.buf[tail % RX_RING_SIZE];
        @atomicStore(u32, &ring.tail, tail +% 1, .release);
        return byte;
    }
};

var rings: [6]RxRing = @splat(.{});

const NVIC_ISER: [*]volatile u32 = @ptrFromInt(0xE000_E100);

fn irqNumber(uart: Uart) u32 {
    return switch (uart) {
        .usart1 => 37,
        .usart2 => 38,
        .usart3 => 39,
        .uart4 => 52,
        .uart5 => 53,
        .usart6 => 71,
    };
}

pub fn enableRxInterrupt(uart: Uart) void {
    const ring = &rings[@intFromEnum(uart)];
    while ((reg(uart, sr).* & 0x0020) != 0) _ = reg(uart, dr).*;
    @atomicStore(bool, &ring.enabled, true, .release);

    reg(uart, cr1).* |= 0x0020;

    const irq = irqNumber(uart);
    NVIC_ISER[irq / 32] = @as(u32, 1) << @intCast(irq % 32);
}

pub fn droppedBytes(uart: Uart) u32 {
    return @atomicLoad(u32, &rings[@intFromEnum(uart)].dropped, .monotonic);
}

fn handleRx(uart: Uart) void {
    const status = reg(uart, sr).*;
    if ((status & 0x002F) != 0) {
        const byte: u8 = @truncate(reg(uart, dr).*);
        if ((status & 0x0020) != 0) rings[@intFromEnum(uart)].push(byte);
    }
}

export fn USART1_IRQHandler() void {
    handleRx(.usart1);
}

pub fn writeStr(uart: Uart, str: []const u8) void {
    for (str) |c| writeByte(uart, c);
}
