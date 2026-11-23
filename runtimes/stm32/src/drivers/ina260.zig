//! INA260 power monitor API :D

const std = @import("std");
const hal = @import("../hal.zig");

pub const ADDR_DEFAULT: u7 = 0x40;

const REG_CONFIG: u8 = 0x00;
const REG_CURRENT: u8 = 0x01;
const REG_BUS_VOLTAGE: u8 = 0x02;
const REG_POWER: u8 = 0x03;
const REG_MFR_ID: u8 = 0xFE;
const REG_DIE_ID: u8 = 0xFF;

const MFR_ID: u16 = 0x5449;
const DIE_ID: u16 = 0x227;

pub const Averaging = enum(u3) { x1, x4, x16, x64, x128, x256, x512, x1024 };

pub const Ina260Error = hal.i2c.Error || error{WrongChipId};

pub const Ina260 = struct {
    bus: hal.i2c.I2c,
    addr: u7,

    pub fn init(bus: hal.i2c.I2c, addr: u7, avg: Averaging) Ina260Error!Ina260 {
        const self: Ina260 = .{ .bus = bus, .addr = addr };

        if (try self.readReg(REG_MFR_ID) != MFR_ID) return error.WrongChipId;
        if ((try self.readReg(REG_DIE_ID)) >> 4 != DIE_ID) return error.WrongChipId;

        const cfg: u16 = 0x6127 | (@as(u16, @intFromEnum(avg)) << 9);
        try self.writeReg(REG_CONFIG, cfg);

        return self;
    }

    pub fn readPowerMw(self: *const Ina260) Ina260Error!u32 {
        const raw = try self.readReg(REG_POWER);
        return @as(u32, raw) * 10;
    }

    pub fn readCurrentMa(self: *const Ina260) Ina260Error!f32 {
        const raw: i16 = @bitCast(try self.readReg(REG_CURRENT));
        return @as(f32, @floatFromInt(raw)) * 1.25;
    }

    pub fn readBusMv(self: *const Ina260) Ina260Error!f32 {
        const raw = try self.readReg(REG_BUS_VOLTAGE);
        return @as(f32, @floatFromInt(raw)) * 1.25;
    }

    fn readReg(self: *const Ina260, r: u8) Ina260Error!u16 {
        var b: [2]u8 = undefined;
        try hal.i2c.writeRead(self.bus, self.addr, &.{r}, &b);
        return std.mem.readInt(u16, &b, .big);
    }

    fn writeReg(self: *const Ina260, r: u8, v: u16) Ina260Error!void {
        var w: [3]u8 = undefined;
        w[0] = r;
        std.mem.writeInt(u16, w[1..3], v, .big);
        try hal.i2c.write(self.bus, self.addr, &w);
    }
};
