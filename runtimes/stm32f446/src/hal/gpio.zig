//! GPIO control!!!!

const rcc = @import("rcc.zig");

pub const Port = enum(u3) { a, b, c, d, e };

pub const Pin = struct {
    port: Port,
    num: u4,
};

const Mode = enum(u2) { input, output, alternate, analog };

const moder = 0x00;
const otyper = 0x04;
const pupdr = 0x0C;
const bsrr = 0x18;
const afrl = 0x20;
const afrh = 0x24;

fn reg(port: Port, offset: u32) *volatile u32 {
    const addr: u32 = 0x4002_0000 + @as(u32, @intFromEnum(port)) * 0x400 + offset;
    return @ptrFromInt(addr);
}

fn setMode(port: Port, pin: u4, mode: Mode) void {
    const shift: u5 = @as(u5, pin) * 2;
    const r = reg(port, moder);
    r.* = (r.* & ~(@as(u32, 0b11) << shift)) | (@as(u32, @intFromEnum(mode)) << shift);
}

pub fn enable(port: Port) void {
    rcc.ahb1enr.* |= @as(u32, 1) << @intFromEnum(port);
}

pub fn output(port: Port, pin: u4) void {
    setMode(port, pin, .output);
}

pub fn alternate(port: Port, pin: u4, af: u4) void {
    const afr = reg(port, if (pin < 8) afrl else afrh);
    const shift: u5 = @as(u5, pin & 7) * 4;
    afr.* = (afr.* & ~(@as(u32, 0xF) << shift)) | (@as(u32, af) << shift);
    setMode(port, pin, .alternate);
}

pub fn openDrain(port: Port, pin: u4) void {
    reg(port, otyper).* |= @as(u32, 1) << pin;
}

pub fn pullUp(port: Port, pin: u4) void {
    const shift: u5 = @as(u5, pin) * 2;
    const r = reg(port, pupdr);
    r.* = (r.* & ~(@as(u32, 0b11) << shift)) | (@as(u32, 0b01) << shift);
}

pub fn set(port: Port, pin: u4) void {
    reg(port, bsrr).* = @as(u32, 1) << pin;
}

pub fn reset(port: Port, pin: u4) void {
    reg(port, bsrr).* = @as(u32, 1) << (@as(u5, pin) + 16);
}
