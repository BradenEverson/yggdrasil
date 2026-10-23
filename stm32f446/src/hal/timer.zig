//! SysTick-based millisecond timer

const SYSTICK_BASE = 0xE000_E010;
const STK_CTRL = @as(*volatile u32, @ptrFromInt(SYSTICK_BASE + 0x00));
const STK_LOAD = @as(*volatile u32, @ptrFromInt(SYSTICK_BASE + 0x04));
const STK_VAL = @as(*volatile u32, @ptrFromInt(SYSTICK_BASE + 0x08));

const CTRL_ENABLE: u32 = 1 << 0;
const CTRL_TICKINT: u32 = 1 << 1;
const CTRL_CLKSOURCE: u32 = 1 << 2;

var ticks: u32 = 0;

pub fn init(cpu_freq_hz: u32) void {
    @atomicStore(u32, &ticks, 0, .monotonic);

    STK_CTRL.* = 0;
    STK_LOAD.* = (cpu_freq_hz / 1000) - 1;
    STK_VAL.* = 0;
    STK_CTRL.* = CTRL_ENABLE | CTRL_TICKINT | CTRL_CLKSOURCE;
}

pub fn millis() u32 {
    return @atomicLoad(u32, &ticks, .monotonic);
}

pub fn delayMs(ms: u32) void {
    const start = millis();
    while (millis() -% start < ms) {
        asm volatile ("wfi");
    }
}

export fn SysTick_Handler() void {
    @atomicStore(u32, &ticks, ticks +% 1, .monotonic);
}
