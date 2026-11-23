pub const gpio = @import("f4/gpio.zig");
pub const uart = @import("f4/uart.zig");
pub const i2c = @import("f4/i2c.zig");
pub const rtc = @import("f4/rtc.zig");
pub const lowpower = @import("f4/lowpower.zig");

const CPACR: *volatile u32 = @ptrFromInt(0xE000_ED88);

pub fn initCpu() void {
    CPACR.* |= 0xF << 20;
    asm volatile ("dsb\n isb");
}
