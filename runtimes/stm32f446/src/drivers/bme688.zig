//! BME688 temperature API :D

const std = @import("std");
const hal = @import("../hal.zig");

pub const ADDR_LOW: u7 = 0x76;
pub const ADDR_HIGH: u7 = 0x77;

const REG_COEFF1: u8 = 0x8A;
const REG_COEFF2: u8 = 0xE1;
const REG_COEFF3: u8 = 0x00;
const REG_FIELD0: u8 = 0x1D;
const REG_RES_HEAT0: u8 = 0x5A;
const REG_GAS_WAIT0: u8 = 0x64;
const REG_CTRL_GAS_0: u8 = 0x70;
const REG_CTRL_GAS_1: u8 = 0x71;
const REG_CTRL_HUM: u8 = 0x72;
const REG_CTRL_MEAS: u8 = 0x74;
const REG_CONFIG: u8 = 0x75;
const REG_VARIANT_ID: u8 = 0xF0;
const REG_CHIP_ID: u8 = 0xD0;
const REG_RESET: u8 = 0xE0;

const CHIP_ID: u8 = 0x61;
const RESET_CMD: u8 = 0xB6;
const FIELD_LEN = 17;

const STATUS_NEW_DATA: u8 = 0x80;
const STATUS_GAS_MEASURING: u8 = 0x40;
const STATUS_MEASURING: u8 = 0x20;

pub const Bme688Error = hal.i2c.Error || error{ WrongChipId, Timeout };

pub const Oversampling = enum(u3) { skip, x1, x2, x4, x8, x16 };
pub const Filter = enum(u3) { off, c1, c3, c7, c15, c31, c63, c127 };

pub const Config = struct {
    temp_os: Oversampling = .x8,
    press_os: Oversampling = .x4,
    hum_os: Oversampling = .x2,
    filter: Filter = .c3,
    gas_enabled: bool = true,
    heater_temp_c: u16 = 320,
    heater_dur_ms: u16 = 150,
};

pub const Reading = struct {
    temperature_c: f32,
    pressure_pa: f32,
    humidity_pct: f32,
    gas_resistance_ohm: f32,
    gas_valid: bool,
    heater_stable: bool,
    gas_adc: u16,
    gas_range: u4,

    pub fn pressureHpa(self: Reading) f32 {
        return self.pressure_pa / 100.0;
    }

    pub fn temperatureF(self: Reading) f32 {
        return self.temperature_c * 9.0 / 5.0 + 32.0;
    }
};

const Calib = struct {
    t1: u16,
    t2: i16,
    t3: i8,
    p1: u16,
    p2: i16,
    p3: i8,
    p4: i16,
    p5: i16,
    p6: i8,
    p7: i8,
    p8: i16,
    p9: i16,
    p10: u8,
    h1: u16,
    h2: u16,
    h3: i8,
    h4: i8,
    h5: i8,
    h6: u8,
    h7: i8,
    gh1: i8,
    gh2: i16,
    gh3: i8,
    res_heat_val: i8,
    res_heat_range: u8,

    fn parse(a: *const [42]u8) Calib {
        return .{
            .t1 = le16(a, 31),
            .t2 = s16(le16(a, 0)),
            .t3 = s8(a[2]),
            .p1 = le16(a, 4),
            .p2 = s16(le16(a, 6)),
            .p3 = s8(a[8]),
            .p4 = s16(le16(a, 10)),
            .p5 = s16(le16(a, 12)),
            .p6 = s8(a[15]),
            .p7 = s8(a[14]),
            .p8 = s16(le16(a, 18)),
            .p9 = s16(le16(a, 20)),
            .p10 = a[22],
            .h1 = (@as(u16, a[25]) << 4) | (a[24] & 0x0F),
            .h2 = (@as(u16, a[23]) << 4) | (a[24] >> 4),
            .h3 = s8(a[26]),
            .h4 = s8(a[27]),
            .h5 = s8(a[28]),
            .h6 = a[29],
            .h7 = s8(a[30]),
            .gh1 = s8(a[35]),
            .gh2 = s16(le16(a, 33)),
            .gh3 = s8(a[36]),
            .res_heat_val = s8(a[37]),
            .res_heat_range = (a[39] & 0x30) >> 4,
        };
    }
};

fn le16(a: *const [42]u8, lsb_idx: usize) u16 {
    return (@as(u16, a[lsb_idx + 1]) << 8) | a[lsb_idx];
}
fn s8(b: u8) i8 {
    return @bitCast(b);
}
fn s16(v: u16) i16 {
    return @bitCast(v);
}
fn f(x: anytype) f32 {
    return @floatFromInt(x);
}
fn clamp(x: f32, lo: f32, hi: f32) f32 {
    if (x < lo) return lo;
    if (x > hi) return hi;
    return x;
}

pub const Bme688 = struct {
    bus: hal.i2c.I2c,
    addr: u7,
    cal: Calib,
    cfg: Config,
    run_gas_bit: u8,
    amb_temp: f32 = 25.0,

    pub fn init(bus: hal.i2c.I2c, addr: u7, cfg: Config) Bme688Error!Bme688 {
        var self: Bme688 = .{
            .bus = bus,
            .addr = addr,
            .cal = undefined,
            .cfg = cfg,
            .run_gas_bit = 0x20,
        };

        try self.writeReg(REG_RESET, RESET_CMD);
        hal.timer.delayMs(10);

        const id = try self.readReg(REG_CHIP_ID);
        if (id != CHIP_ID) {
            return error.WrongChipId;
        }

        const variant = try self.readReg(REG_VARIANT_ID);
        self.run_gas_bit = if (variant == 0x00) 0x10 else 0x20;

        try self.readCalibration();
        return self;
    }

    pub fn measure(self: *Bme688) Bme688Error!Reading {
        try self.triggerForced();

        hal.timer.delayMs(self.estimateDurationMs());

        var b: [FIELD_LEN]u8 = undefined;
        var waited: u32 = 0;
        while (true) {
            try self.readRegs(REG_FIELD0, &b);
            const done = (b[0] & STATUS_NEW_DATA) != 0 and
                (b[0] & (STATUS_MEASURING | STATUS_GAS_MEASURING)) == 0;
            if (done) break;
            if (waited >= 1000) return error.Timeout;
            hal.timer.delayMs(10);
            waited += 10;
        }

        const r = self.compensate(&b);
        self.amb_temp = r.temperature_c;
        return r;
    }

    fn readCalibration(self: *Bme688) Bme688Error!void {
        var a: [42]u8 = undefined;
        try self.readRegs(REG_COEFF1, a[0..23]);
        try self.readRegs(REG_COEFF2, a[23..37]);
        try self.readRegs(REG_COEFF3, a[37..42]);
        self.cal = Calib.parse(&a);
    }

    fn triggerForced(self: *Bme688) Bme688Error!void {
        const cfg = self.cfg;

        try self.writeReg(REG_CTRL_HUM, @intFromEnum(cfg.hum_os));
        try self.writeReg(REG_CONFIG, @as(u8, @intFromEnum(cfg.filter)) << 2);

        if (cfg.gas_enabled) {
            try self.writeReg(REG_RES_HEAT0, self.calcResHeat(cfg.heater_temp_c));
            try self.writeReg(REG_GAS_WAIT0, calcGasWait(cfg.heater_dur_ms));
            try self.writeReg(REG_CTRL_GAS_0, 0x00);
            try self.writeReg(REG_CTRL_GAS_1, self.run_gas_bit);
        } else {
            try self.writeReg(REG_CTRL_GAS_0, 0x08);
            try self.writeReg(REG_CTRL_GAS_1, 0x00);
        }

        const ctrl_meas: u8 = (@as(u8, @intFromEnum(cfg.temp_os)) << 5) |
            (@as(u8, @intFromEnum(cfg.press_os)) << 2) |
            0x01;
        try self.writeReg(REG_CTRL_MEAS, ctrl_meas);
    }

    fn estimateDurationMs(self: *const Bme688) u32 {
        const cyc = [_]u32{ 0, 1, 2, 4, 8, 16 };
        const cycles = cyc[@intFromEnum(self.cfg.temp_os)] +
            cyc[@intFromEnum(self.cfg.press_os)] +
            cyc[@intFromEnum(self.cfg.hum_os)];
        var us: u32 = cycles * 1963 + 477 * 4;
        if (self.cfg.gas_enabled) us += 477 * 5;
        var ms = us / 1000 + 1;
        if (self.cfg.gas_enabled) ms += self.cfg.heater_dur_ms;
        return ms;
    }

    fn calcResHeat(self: *const Bme688, target_c: u16) u8 {
        const c = &self.cal;
        const t: f32 = @floatFromInt(@min(target_c, 400));
        const var1 = (f(c.gh1) / 16.0) + 49.0;
        const var2 = ((f(c.gh2) / 32768.0) * 0.0005) + 0.00235;
        const var3 = f(c.gh3) / 1024.0;
        const var4 = var1 * (1.0 + (var2 * t));
        const var5 = var4 + (var3 * self.amb_temp);
        const r = 3.4 * ((var5 *
            (4.0 / (4.0 + f(c.res_heat_range))) *
            (1.0 / (1.0 + (f(c.res_heat_val) * 0.002)))) - 25.0);
        return @intFromFloat(clamp(r, 0.0, 255.0));
    }

    fn compensate(self: *const Bme688, b: *const [FIELD_LEN]u8) Reading {
        const c = &self.cal;

        const press_adc: u32 = (@as(u32, b[2]) << 12) | (@as(u32, b[3]) << 4) | (b[4] >> 4);
        const temp_adc: u32 = (@as(u32, b[5]) << 12) | (@as(u32, b[6]) << 4) | (b[7] >> 4);
        const hum_adc: u32 = (@as(u32, b[8]) << 8) | b[9];
        const gas_adc: u16 = (@as(u16, b[15]) << 2) | (b[16] >> 6);
        const gas_range: u4 = @truncate(b[16] & 0x0F);

        const ta = f(temp_adc);
        const t1 = f(c.t1);
        const t_var1 = ((ta / 16384.0) - (t1 / 1024.0)) * f(c.t2);
        const td = (ta / 131072.0) - (t1 / 8192.0);
        const t_var2 = td * td * (f(c.t3) * 16.0);
        const t_fine = t_var1 + t_var2;
        const temp = t_fine / 5120.0;

        var v1 = (t_fine / 2.0) - 64000.0;
        var v2 = v1 * v1 * (f(c.p6) / 131072.0);
        v2 = v2 + (v1 * f(c.p5) * 2.0);
        v2 = (v2 / 4.0) + (f(c.p4) * 65536.0);
        v1 = (((f(c.p3) * v1 * v1) / 16384.0) + (f(c.p2) * v1)) / 524288.0;
        v1 = (1.0 + (v1 / 32768.0)) * f(c.p1);
        var press: f32 = 1048576.0 - f(press_adc);
        if (v1 != 0.0) {
            press = ((press - (v2 / 4096.0)) * 6250.0) / v1;
            v1 = (f(c.p9) * press * press) / 2147483648.0;
            v2 = press * (f(c.p8) / 32768.0);
            const v3 = (press / 256.0) * (press / 256.0) * (press / 256.0) * (f(c.p10) / 131072.0);
            press = press + (v1 + v2 + v3 + (f(c.p7) * 128.0)) / 16.0;
        } else {
            press = 0.0;
        }

        const hv1 = f(hum_adc) - ((f(c.h1) * 16.0) + ((f(c.h3) / 2.0) * temp));
        const hv2 = hv1 * ((f(c.h2) / 262144.0) *
            (1.0 + ((f(c.h4) / 16384.0) * temp) + ((f(c.h5) / 1048576.0) * temp * temp)));
        const hv3 = f(c.h6) / 16384.0;
        const hv4 = f(c.h7) / 2097152.0;
        const hum = clamp(hv2 + ((hv3 + (hv4 * temp)) * hv2 * hv2), 0.0, 100.0);

        const g1: u32 = @as(u32, 262144) >> gas_range;
        const g2: f32 = 4096.0 + 3.0 * (f(gas_adc) - 512.0);
        const gas_res: f32 = 1_000_000.0 * f(g1) / g2;

        const gas_on = self.cfg.gas_enabled;
        return .{
            .temperature_c = temp,
            .pressure_pa = press,
            .humidity_pct = hum,
            .gas_resistance_ohm = if (gas_on) gas_res else 0.0,
            .gas_valid = gas_on and (b[16] & 0x20) != 0,
            .heater_stable = gas_on and (b[16] & 0x10) != 0,
            .gas_adc = gas_adc,
            .gas_range = gas_range,
        };
    }

    fn readRegs(self: *const Bme688, r: u8, buf: []u8) Bme688Error!void {
        try hal.i2c.writeRead(self.bus, self.addr, &.{r}, buf);
    }

    fn readReg(self: *const Bme688, r: u8) Bme688Error!u8 {
        var v: [1]u8 = undefined;
        try self.readRegs(r, &v);
        return v[0];
    }

    fn writeReg(self: *const Bme688, r: u8, v: u8) Bme688Error!void {
        try hal.i2c.write(self.bus, self.addr, &.{ r, v });
    }
};

fn calcGasWait(dur_ms: u16) u8 {
    if (dur_ms >= 0xFC0) return 0xFF;
    var d: u16 = dur_ms;
    var factor: u16 = 0;
    while (d > 0x3F) {
        d /= 4;
        factor += 1;
    }
    return @intCast(d + factor * 64);
}
