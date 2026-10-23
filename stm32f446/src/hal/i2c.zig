//! I2C :DDDD

const std = @import("std");
const gpio = @import("gpio.zig");
const rcc = @import("rcc.zig");

pub const I2c = enum { i2c1, i2c2, i2c3 };

const Signal = enum { scl, sda };

const PinOption = struct { i2c: I2c, signal: Signal, port: gpio.Port, pin: u4, af: u4 };

const pin_options = [_]PinOption{
    // I2C1
    .{ .i2c = .i2c1, .signal = .scl, .port = .b, .pin = 6, .af = 4 },
    .{ .i2c = .i2c1, .signal = .scl, .port = .b, .pin = 8, .af = 4 },
    .{ .i2c = .i2c1, .signal = .sda, .port = .b, .pin = 7, .af = 4 },
    .{ .i2c = .i2c1, .signal = .sda, .port = .b, .pin = 9, .af = 4 },
    // I2C2
    .{ .i2c = .i2c2, .signal = .scl, .port = .b, .pin = 10, .af = 4 },
    .{ .i2c = .i2c2, .signal = .sda, .port = .b, .pin = 11, .af = 4 },
    .{ .i2c = .i2c2, .signal = .sda, .port = .b, .pin = 3, .af = 9 },
    .{ .i2c = .i2c2, .signal = .sda, .port = .b, .pin = 9, .af = 9 },
    // I2C3
    .{ .i2c = .i2c3, .signal = .scl, .port = .a, .pin = 8, .af = 4 },
    .{ .i2c = .i2c3, .signal = .sda, .port = .c, .pin = 9, .af = 4 },
    .{ .i2c = .i2c3, .signal = .sda, .port = .b, .pin = 4, .af = 9 },
    .{ .i2c = .i2c3, .signal = .sda, .port = .b, .pin = 8, .af = 9 },
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
        .i2c3 => 0x4000_5C00,
    };
}

const cr1 = 0x00;
const cr2 = 0x04;
const dr = 0x10;
const sr1 = 0x14;
const sr2 = 0x18;
const ccr = 0x1C;
const trise = 0x20;

fn reg(i2c: I2c, offset: u32) *volatile u32 {
    return @ptrFromInt(baseAddr(i2c) + offset);
}

const CR1_PE: u32 = 1 << 0;
const CR1_START: u32 = 1 << 8;
const CR1_STOP: u32 = 1 << 9;
const CR1_ACK: u32 = 1 << 10;
const CR1_POS: u32 = 1 << 11;
const SR1_SB: u32 = 1 << 0;
const SR1_ADDR: u32 = 1 << 1;
const SR1_BTF: u32 = 1 << 2;
const SR1_RXNE: u32 = 1 << 6;
const SR1_TXE: u32 = 1 << 7;
const SR1_BERR: u32 = 1 << 8;
const SR1_ARLO: u32 = 1 << 9;
const SR1_AF: u32 = 1 << 10;
const SR2_BUSY: u32 = 1 << 1;

const pclk1: u32 = 16_000_000;

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

pub fn init(comptime i2c: I2c, comptime config: Config) void {
    rcc.apb1enr.* |= @as(u32, 1) << (21 + @as(u5, @intFromEnum(i2c)));

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

    reg(i2c, cr1).* = 0;
    reg(i2c, cr2).* = pclk1 / 1_000_000;
    reg(i2c, ccr).* = ccrValue(config.speed);
    reg(i2c, trise).* = triseValue(config.speed);
    reg(i2c, cr1).* = CR1_PE;
}

pub fn write(i2c: I2c, addr: u7, data: []const u8) Error!void {
    try waitBusyClear(i2c);
    try writePhase(i2c, addr, data, true);
}

pub fn read(i2c: I2c, addr: u7, buf: []u8) Error!void {
    try waitBusyClear(i2c);
    try readPhase(i2c, addr, buf);
}

pub fn writeRead(i2c: I2c, addr: u7, tx: []const u8, rx: []u8) Error!void {
    try waitBusyClear(i2c);
    try writePhase(i2c, addr, tx, false);
    try readPhase(i2c, addr, rx);
}

pub fn probe(i2c: I2c, addr: u7) bool {
    write(i2c, addr, &.{}) catch return false;
    return true;
}

fn ccrValue(speed: Speed) u32 {
    return switch (speed) {
        .standard => (pclk1 + 2 * 100_000 - 1) / (2 * 100_000),
        .fast => (1 << 15) | ((pclk1 + 3 * 400_000 - 1) / (3 * 400_000)),
    };
}

fn triseValue(speed: Speed) u32 {
    const mhz = pclk1 / 1_000_000;
    return switch (speed) {
        .standard => mhz + 1,
        .fast => mhz * 3 / 10 + 1,
    };
}

fn setBits(i2c: I2c, mask: u32) void {
    reg(i2c, cr1).* |= mask;
}

fn clearBits(i2c: I2c, mask: u32) void {
    reg(i2c, cr1).* &= ~mask;
}

fn abort(i2c: I2c, err: Error) Error {
    reg(i2c, sr1).* &= ~(SR1_AF | SR1_BERR | SR1_ARLO);
    setBits(i2c, CR1_STOP);
    return err;
}

fn waitFlag(i2c: I2c, mask: u32) Error!void {
    var polls: u32 = 0;
    while (true) {
        const s = reg(i2c, sr1).*;
        if (s & mask != 0) return;
        if (s & SR1_AF != 0) return abort(i2c, error.Nack);
        if (s & (SR1_BERR | SR1_ARLO) != 0) return abort(i2c, error.BusError);
        polls += 1;
        if (polls >= timeout_polls) return abort(i2c, error.Timeout);
    }
}

fn waitBusyClear(i2c: I2c) Error!void {
    var polls: u32 = 0;
    while (reg(i2c, sr2).* & SR2_BUSY != 0) {
        polls += 1;
        if (polls >= timeout_polls) return error.Timeout;
    }
}

fn start(i2c: I2c) Error!void {
    setBits(i2c, CR1_START);
    try waitFlag(i2c, SR1_SB);
}

fn sendAddress(i2c: I2c, addr: u7, is_read: bool) Error!void {
    reg(i2c, dr).* = (@as(u32, addr) << 1) | @intFromBool(is_read);
    try waitFlag(i2c, SR1_ADDR);
}

fn clearAddr(i2c: I2c) void {
    _ = reg(i2c, sr1).*;
    _ = reg(i2c, sr2).*;
}

fn writePhase(i2c: I2c, addr: u7, data: []const u8, stop: bool) Error!void {
    try start(i2c);
    try sendAddress(i2c, addr, false);
    clearAddr(i2c);

    for (data) |byte| {
        try waitFlag(i2c, SR1_TXE);
        reg(i2c, dr).* = byte;
    }
    if (data.len > 0) try waitFlag(i2c, SR1_BTF);

    if (stop) setBits(i2c, CR1_STOP);
}

fn readPhase(i2c: I2c, addr: u7, buf: []u8) Error!void {
    if (buf.len == 0) return;

    clearBits(i2c, CR1_POS);
    setBits(i2c, CR1_ACK);
    if (buf.len == 2) setBits(i2c, CR1_POS);

    try start(i2c);
    try sendAddress(i2c, addr, true);

    switch (buf.len) {
        1 => {
            clearBits(i2c, CR1_ACK);
            clearAddr(i2c);
            setBits(i2c, CR1_STOP);
            try waitFlag(i2c, SR1_RXNE);
            buf[0] = @truncate(reg(i2c, dr).*);
        },
        2 => {
            clearAddr(i2c);
            clearBits(i2c, CR1_ACK);
            try waitFlag(i2c, SR1_BTF);
            setBits(i2c, CR1_STOP);
            buf[0] = @truncate(reg(i2c, dr).*);
            buf[1] = @truncate(reg(i2c, dr).*);
        },
        else => {
            clearAddr(i2c);
            var i: usize = 0;
            while (buf.len - i > 3) : (i += 1) {
                try waitFlag(i2c, SR1_RXNE);
                buf[i] = @truncate(reg(i2c, dr).*);
            }
            try waitFlag(i2c, SR1_BTF);
            clearBits(i2c, CR1_ACK);
            buf[i] = @truncate(reg(i2c, dr).*);
            try waitFlag(i2c, SR1_BTF);
            setBits(i2c, CR1_STOP);
            buf[i + 1] = @truncate(reg(i2c, dr).*);
            buf[i + 2] = @truncate(reg(i2c, dr).*);
        },
    }

    clearBits(i2c, CR1_POS);
    setBits(i2c, CR1_ACK);
}
