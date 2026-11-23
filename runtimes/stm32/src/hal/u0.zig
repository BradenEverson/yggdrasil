pub const gpio = @import("u0/gpio.zig");
pub const uart = @import("u0/uart.zig");
pub const i2c = @import("u0/i2c.zig");
pub const rtc = @import("u0/rtc.zig");
pub const lowpower = @import("u0/lowpower.zig");

const rcc = @import("u0/rcc.zig");

const CR_HSION: u32 = 1 << 8;
const CR_HSIRDY: u32 = 1 << 10;
const CR_MSION: u32 = 1 << 0;
const CFGR_SW_MASK: u32 = 0b111;
const CFGR_SWS_MASK: u32 = 0b111 << 3;
const CFGR_SW_HSI16: u32 = 0b001;
const CFGR_STOPWUCK: u32 = 1 << 15;

pub fn initCpu() void {
    rcc.cr.* |= CR_HSION;
    while (rcc.cr.* & CR_HSIRDY == 0) {}
    rcc.cfgr.* = (rcc.cfgr.* & ~CFGR_SW_MASK) | CFGR_SW_HSI16 | CFGR_STOPWUCK;
    while (rcc.cfgr.* & CFGR_SWS_MASK != CFGR_SW_HSI16 << 3) {}
    rcc.cr.* &= ~CR_MSION;
}

fn barrier() void {
    asm volatile ("dmb" ::: .{ .memory = true });
}

fn AtomicOps(comptime T: type) type {
    return struct {
        fn load(ptr: *const volatile T, _: c_int) callconv(.c) T {
            barrier();
            const v = ptr.*;
            barrier();
            return v;
        }

        fn store(ptr: *volatile T, value: T, _: c_int) callconv(.c) void {
            barrier();
            ptr.* = value;
            barrier();
        }
    };
}

comptime {
    for (.{ .{ u8, "1" }, .{ u16, "2" }, .{ u32, "4" } }) |entry| {
        const ops = AtomicOps(entry[0]);
        @export(&ops.load, .{ .name = "__atomic_load_" ++ entry[1] });
        @export(&ops.store, .{ .name = "__atomic_store_" ++ entry[1] });
    }
}
