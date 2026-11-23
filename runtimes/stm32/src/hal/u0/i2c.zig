const std = @import("std");
const gpio = @import("gpio.zig");
const rcc = @import("rcc.zig");

pub const I2c = enum { i2c1, i2c2, i2c3 };

const Signal = enum { scl, sda };

const PinOption = struct { i2c: I2c, signal: Signal, port: gpio.Port, pin: u4, af: u4 };

const pin_options = [_]PinOption{
    .{ .i2c = .i2c1, .signal = .scl, .port = .a, .pin = 9, .af = 4 },
    .{ .i2c = .i2c1, .signal = .scl, .port = .b, .pin = 6, .af = 4 },
    .{ .i2c = .i2c1, .signal = .scl, .port = .b, .pin = 8, .af = 4 },
    .{ .i2c = .i2c1, .signal = .sda, .port = .a, .pin = 10, .af = 4 },
    .{ .i2c = .i2c1, .signal = .sda, .port = .b, .pin = 7, .af = 4 },
    .{ .i2c = .i2c1, .signal = .sda, .port = .b, .pin = 9, .af = 4 },
    .{ .i2c = .i2c2, .signal = .scl, .port = .a, .pin = 7, .af = 3 },
    .{ .i2c = .i2c2, .signal = .scl, .port = .a, .pin = 9, .af = 5 },
    .{ .i2c = .i2c2, .signal = .scl, .port = .b, .pin = 3, .af = 3 },
    .{ .i2c = .i2c2, .signal = .scl, .port = .b, .pin = 6, .af = 5 },
    .{ .i2c = .i2c2, .signal = .scl, .port = .b, .pin = 8, .af = 3 },
    .{ .i2c = .i2c2, .signal = .scl, .port = .b, .pin = 10, .af = 4 },
    .{ .i2c = .i2c2, .signal = .scl, .port = .b, .pin = 13, .af = 4 },
    .{ .i2c = .i2c2, .signal = .sda, .port = .a, .pin = 6, .af = 3 },
    .{ .i2c = .i2c2, .signal = .sda, .port = .a, .pin = 10, .af = 5 },
    .{ .i2c = .i2c2, .signal = .sda, .port = .b, .pin = 4, .af = 3 },
    .{ .i2c = .i2c2, .signal = .sda, .port = .b, .pin = 7, .af = 5 },
    .{ .i2c = .i2c2, .signal = .sda, .port = .b, .pin = 9, .af = 3 },
    .{ .i2c = .i2c2, .signal = .sda, .port = .b, .pin = 11, .af = 4 },
    .{ .i2c = .i2c2, .signal = .sda, .port = .b, .pin = 14, .af = 4 },
    .{ .i2c = .i2c3, .signal = .scl, .port = .a, .pin = 7, .af = 4 },
    .{ .i2c = .i2c3, .signal = .scl, .port = .b, .pin = 3, .af = 4 },
    .{ .i2c = .i2c3, .signal = .scl, .port = .c, .pin = 0, .af = 4 },
    .{ .i2c = .i2c3, .signal = .sda, .port = .a, .pin = 6, .af = 4 },
    .{ .i2c = .i2c3, .signal = .sda, .port = .b, .pin = 4, .af = 4 },
    .{ .i2c = .i2c3, .signal = .sda, .port = .c, .pin = 1, .af = 4 },
};

fn afFor(comptime i2c: I2c, comptime signal: Signal, comptime pin: gpio.Pin) u4 {
    for (pin_options) |o| {
        if (o.i2c == i2c and o.signal == signal and o.port == pin.port and o.pin == pin.num)
            return o.af;
    }
    @compileError(std.fmt.comptimePrint(
        "P{s}{d} cannot be {s} for {s}",
        .{ @tagName(pin.port), pin.num, @tagName(signal), @tagName(i2c) },
    ));
}

fn baseAddr(i2c: I2c) u32 {
    return switch (i2c) {
        .i2c1 => 0x4000_5400,
        .i2c2 => 0x4000_5800,
        .i2c3 => 0x4000_8800,
    };
}

const cr1 = 0x00;
const cr2 = 0x04;
const timingr = 0x10;
const isr = 0x18;
const icr = 0x1C;
const rxdr = 0x24;
const txdr = 0x28;

fn reg(i2c: I2c, offset: u32) *volatile u32 {
    return @ptrFromInt(baseAddr(i2c) + offset);
}

const CR1_PE: u32 = 1 << 0;

const CR2_RD_WRN: u32 = 1 << 10;
const CR2_START: u32 = 1 << 13;
const CR2_STOP: u32 = 1 << 14;
const CR2_NBYTES_SHIFT: u5 = 16;
const CR2_RELOAD: u32 = 1 << 24;
const CR2_AUTOEND: u32 = 1 << 25;

const ISR_TXE: u32 = 1 << 0;
const ISR_TXIS: u32 = 1 << 1;
const ISR_RXNE: u32 = 1 << 2;
const ISR_NACKF: u32 = 1 << 4;
const ISR_STOPF: u32 = 1 << 5;
const ISR_TC: u32 = 1 << 6;
const ISR_TCR: u32 = 1 << 7;
const ISR_BERR: u32 = 1 << 8;
const ISR_ARLO: u32 = 1 << 9;
const ISR_BUSY: u32 = 1 << 15;

const ICR_NACKCF: u32 = 1 << 4;
const ICR_STOPCF: u32 = 1 << 5;
const ICR_BERRCF: u32 = 1 << 8;
const ICR_ARLOCF: u32 = 1 << 9;

const MAX_CHUNK: usize = 255;

const timeout_polls: u32 = 100_000;

pub const Error = error{ Nack, Timeout, BusError };

pub const Speed = enum {
    standard,
    fast,
};

pub const Config = struct {
    scl: gpio.Pin,
    sda: gpio.Pin,
    speed: Speed = .standard,
    internal_pullups: bool = false,
};

fn timing(speed: Speed) u32 {
    return switch (speed) {
        .standard => 0x3042_0F13,
        .fast => 0x1032_0309,
    };
}

pub fn init(comptime i2c: I2c, comptime config: Config) void {
    rcc.apbenr1.* |= @as(u32, 1) << (21 + @as(u5, @intFromEnum(i2c)));
    attachPins(i2c, config);

    reg(i2c, cr1).* = 0;
    reg(i2c, timingr).* = timing(config.speed);
    reg(i2c, cr1).* = CR1_PE;
}

pub fn attachPins(comptime i2c: I2c, comptime config: Config) void {
    inline for (.{
        .{ config.scl, Signal.scl },
        .{ config.sda, Signal.sda },
    }) |line| {
        const pin: gpio.Pin = line[0];
        gpio.enable(pin.port);
        gpio.openDrain(pin.port, pin.num);
        if (config.internal_pullups) gpio.pullUp(pin.port, pin.num);
        gpio.alternate(pin.port, pin.num, comptime afFor(i2c, line[1], pin));
    }
}

pub fn detachPins(comptime config: Config) void {
    gpio.analog(config.scl);
    gpio.analog(config.sda);
}

pub fn write(i2c: I2c, addr: u7, data: []const u8) Error!void {
    try waitBusyClear(i2c);
    try writePhase(i2c, addr, data, true);
    try finishStop(i2c);
}

pub fn read(i2c: I2c, addr: u7, buf: []u8) Error!void {
    try waitBusyClear(i2c);
    try readPhase(i2c, addr, buf);
    try finishStop(i2c);
}

pub fn writeRead(i2c: I2c, addr: u7, tx: []const u8, rx: []u8) Error!void {
    try waitBusyClear(i2c);
    try writePhase(i2c, addr, tx, rx.len == 0);
    if (rx.len > 0) {
        try waitFlag(i2c, ISR_TC);
        try readPhase(i2c, addr, rx);
    }
    try finishStop(i2c);
}

pub fn probe(i2c: I2c, addr: u7) bool {
    write(i2c, addr, &.{}) catch return false;
    return true;
}

fn resetPeripheral(i2c: I2c) void {
    reg(i2c, cr1).* &= ~CR1_PE;
    while (reg(i2c, cr1).* & CR1_PE != 0) {}
    reg(i2c, cr1).* |= CR1_PE;
}

fn abort(i2c: I2c, err: Error) Error {
    switch (err) {
        error.Nack => {
            if (reg(i2c, cr2).* & CR2_AUTOEND == 0) reg(i2c, cr2).* |= CR2_STOP;
            var polls: u32 = 0;
            while (reg(i2c, isr).* & ISR_STOPF == 0 and polls < timeout_polls) : (polls += 1) {}
            reg(i2c, icr).* = ICR_NACKCF | ICR_STOPCF;
            reg(i2c, isr).* = ISR_TXE;
        },
        error.BusError => {
            reg(i2c, icr).* = ICR_BERRCF | ICR_ARLOCF;
            resetPeripheral(i2c);
        },
        error.Timeout => resetPeripheral(i2c),
    }
    reg(i2c, cr2).* = 0;
    return err;
}

fn waitFlag(i2c: I2c, mask: u32) Error!void {
    var polls: u32 = 0;
    while (true) {
        const s = reg(i2c, isr).*;
        if (s & ISR_NACKF != 0) return abort(i2c, error.Nack);
        if (s & (ISR_BERR | ISR_ARLO) != 0) return abort(i2c, error.BusError);
        if (s & mask != 0) return;
        polls += 1;
        if (polls >= timeout_polls) return abort(i2c, error.Timeout);
    }
}

fn waitBusyClear(i2c: I2c) Error!void {
    var polls: u32 = 0;
    while (reg(i2c, isr).* & ISR_BUSY != 0) {
        polls += 1;
        if (polls >= timeout_polls) return abort(i2c, error.Timeout);
    }
}

fn finishStop(i2c: I2c) Error!void {
    try waitFlag(i2c, ISR_STOPF);
    reg(i2c, icr).* = ICR_STOPCF;
    reg(i2c, cr2).* = 0;
}

fn chunkBits(remaining: usize, autoend: bool) u32 {
    const n = @min(remaining, MAX_CHUNK);
    var bits = @as(u32, @intCast(n)) << CR2_NBYTES_SHIFT;
    if (remaining > MAX_CHUNK) bits |= CR2_RELOAD else if (autoend) bits |= CR2_AUTOEND;
    return bits;
}

fn startTransfer(i2c: I2c, addr: u7, len: usize, is_read: bool, autoend: bool) void {
    var bits = (@as(u32, addr) << 1) | CR2_START | chunkBits(len, autoend);
    if (is_read) bits |= CR2_RD_WRN;
    reg(i2c, cr2).* = bits;
}

fn reloadIfNeeded(i2c: I2c, done: usize, total: usize, autoend: bool) Error!void {
    if (done == 0 or done == total or done % MAX_CHUNK != 0) return;
    try waitFlag(i2c, ISR_TCR);
    const keep = reg(i2c, cr2).* & (0x3FF | CR2_RD_WRN);
    reg(i2c, cr2).* = keep | chunkBits(total - done, autoend);
}

fn writePhase(i2c: I2c, addr: u7, data: []const u8, stop: bool) Error!void {
    startTransfer(i2c, addr, data.len, false, stop);
    for (data, 0..) |byte, i| {
        try reloadIfNeeded(i2c, i, data.len, stop);
        try waitFlag(i2c, ISR_TXIS);
        reg(i2c, txdr).* = byte;
    }
}

fn readPhase(i2c: I2c, addr: u7, buf: []u8) Error!void {
    startTransfer(i2c, addr, buf.len, true, true);
    for (buf, 0..) |*byte, i| {
        try reloadIfNeeded(i2c, i, buf.len, true);
        try waitFlag(i2c, ISR_RXNE);
        byte.* = @truncate(reg(i2c, rxdr).*);
    }
}
