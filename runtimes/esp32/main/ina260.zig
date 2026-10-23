const std = @import("std");
const idf = @import("esp_idf");
const sys = idf.sys;

pub const ADDR_DEFAULT: u16 = 0x40;

const REG_CONFIG: u8 = 0x00;
const REG_CURRENT: u8 = 0x01;
const REG_BUS_VOLTAGE: u8 = 0x02;
const REG_POWER: u8 = 0x03;
const REG_MFR_ID: u8 = 0xFE;
const REG_DIE_ID: u8 = 0xFF;

const MFR_ID: u16 = 0x5449;
const DIE_ID: u16 = 0x227;

pub const Averaging = enum(u3) { x1, x4, x16, x64, x128, x256, x512, x1024 };

const I2C_TIMEOUT_MS: c_int = 100;

extern fn shim_i2c_add_device(
    bus: sys.i2c_master_bus_handle_t,
    addr: u16,
    hz: u32,
    out: *sys.i2c_master_dev_handle_t,
) sys.esp_err_t;

pub const Ina260Error = error{ I2c, WrongChipId };

fn check(rc: sys.esp_err_t) Ina260Error!void {
    if (rc != 0) return error.I2c;
}

pub const Ina260 = struct {
    dev: sys.i2c_master_dev_handle_t,

    pub fn init(
        bus: sys.i2c_master_bus_handle_t,
        addr: u16,
        i2c_hz: u32,
        avg: Averaging,
    ) Ina260Error!Ina260 {
        var dev: sys.i2c_master_dev_handle_t = null;
        try check(shim_i2c_add_device(bus, addr, i2c_hz, &dev));
        errdefer _ = sys.i2c_master_bus_rm_device(dev);

        var self: Ina260 = .{ .dev = dev };

        if (try self.readReg(REG_MFR_ID) != MFR_ID) return error.WrongChipId;
        if ((try self.readReg(REG_DIE_ID)) >> 4 != DIE_ID) return error.WrongChipId;

        const cfg: u16 = 0x6127 | (@as(u16, @intFromEnum(avg)) << 9);
        try self.writeReg(REG_CONFIG, cfg);

        return self;
    }

    pub fn deinit(self: *Ina260) void {
        _ = sys.i2c_master_bus_rm_device(self.dev);
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
        const w = [1]u8{r};
        var b: [2]u8 = undefined;
        try check(sys.i2c_master_transmit_receive(
            self.dev,
            &w,
            1,
            &b,
            2,
            I2C_TIMEOUT_MS,
        ));
        return std.mem.readInt(u16, &b, .big);
    }

    fn writeReg(self: *const Ina260, r: u8, v: u16) Ina260Error!void {
        var w: [3]u8 = undefined;
        w[0] = r;
        std.mem.writeInt(u16, w[1..3], v, .big);
        try check(sys.i2c_master_transmit(self.dev, &w, 3, I2C_TIMEOUT_MS));
    }
};
