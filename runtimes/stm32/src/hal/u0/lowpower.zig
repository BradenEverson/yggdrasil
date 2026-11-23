const rtc = @import("rtc.zig");
const timer = @import("../common/timer.zig");
const gpio = @import("gpio.zig");

const SCB_SCR: *volatile u32 = @ptrFromInt(0xE000_ED10);
const SCR_SLEEPDEEP: u32 = 1 << 2;

const PWR_CR1: *volatile u32 = @ptrFromInt(0x4000_7000);
const CR1_LPMS_MASK: u32 = 0b111;
const CR1_LPMS_STOP2: u32 = 0b010;
const CR1_LPR: u32 = 1 << 14;

pub const MIN_STOP_MS: u32 = 3;

pub fn idle() void {
    asm volatile ("wfi");
}

fn enterStop() void {
    PWR_CR1.* = (PWR_CR1.* & ~(CR1_LPMS_MASK | CR1_LPR)) | CR1_LPMS_STOP2;
    timer.pause();
    SCB_SCR.* |= SCR_SLEEPDEEP;
    asm volatile ("dsb\n wfi\n isb");
    SCB_SCR.* &= ~SCR_SLEEPDEEP;
    timer.unpause();
}

pub fn stopUntil(deadline: u32) void {
    while (true) {
        const left: i32 = @bitCast(deadline -% rtc.millis());
        if (left < @as(i32, @intCast(MIN_STOP_MS))) return;
        rtc.armWakeup(@intCast(left));
        enterStop();
        rtc.disarmWakeup();
    }
}

pub fn stopFor(ms: u32) void {
    stopUntil(rtc.millis() +% ms);
}

pub fn parkUnusedPins(comptime keep: []const gpio.Pin) void {
    const ports = [_]gpio.Port{ .a, .b, .c, .d, .f };
    inline for (ports) |port| {
        gpio.enable(port);
        var mask: u16 = 0xFFFF;
        inline for (keep) |pin| {
            if (pin.port == port) mask &= ~(@as(u16, 1) << pin.num);
        }
        gpio.analogMask(port, mask);
    }
    gpio.disable(.c);
    gpio.disable(.d);
    gpio.disable(.f);
}
