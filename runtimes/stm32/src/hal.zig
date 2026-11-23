//! Hardware Abstraction Layer of Fun and Happiness!!!

const target = @import("target");

const chip = switch (target.chip) {
    .f446 => @import("hal/f4.zig"),
    .u073 => @import("hal/u0.zig"),
};

pub const gpio = chip.gpio;
pub const uart = chip.uart;
pub const i2c = chip.i2c;
pub const rtc = chip.rtc;
pub const lowpower = chip.lowpower;
pub const timer = @import("hal/common/timer.zig");

fn copyForward(dest: [*]volatile u8, src: [*]const u8, n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) dest[i] = src[i];
}

fn copyBackward(dest: [*]volatile u8, src: [*]const u8, n: usize) void {
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        dest[i] = src[i];
    }
}

fn fill(dest: [*]volatile u8, value: u8, n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) dest[i] = value;
}

pub export fn __aeabi_memcpy(dest: ?[*]u8, src: ?[*]const u8, n: usize) void {
    if (n == 0) return;
    copyForward(dest.?, src.?, n);
}

export fn __aeabi_memmove(dest: ?[*]u8, src: ?[*]const u8, n: usize) void {
    if (n == 0) return;
    const d = dest.?;
    const s = src.?;
    if (@intFromPtr(d) > @intFromPtr(s)) {
        copyBackward(d, s, n);
    } else {
        copyForward(d, s, n);
    }
}

export fn __aeabi_memset(dest: ?[*]u8, n: usize, value: c_int) void {
    if (n == 0) return;
    fill(dest.?, @truncate(@as(c_uint, @bitCast(value))), n);
}

export fn __aeabi_memclr(dest: ?[*]u8, n: usize) void {
    if (n == 0) return;
    fill(dest.?, 0, n);
}

export fn __aeabi_memcpy4(dest: ?[*]u8, src: ?[*]const u8, n: usize) void {
    __aeabi_memcpy(dest, src, n);
}
export fn __aeabi_memcpy8(dest: ?[*]u8, src: ?[*]const u8, n: usize) void {
    __aeabi_memcpy(dest, src, n);
}
export fn __aeabi_memmove4(dest: ?[*]u8, src: ?[*]const u8, n: usize) void {
    __aeabi_memmove(dest, src, n);
}
export fn __aeabi_memmove8(dest: ?[*]u8, src: ?[*]const u8, n: usize) void {
    __aeabi_memmove(dest, src, n);
}
export fn __aeabi_memset4(dest: ?[*]u8, n: usize, value: c_int) void {
    __aeabi_memset(dest, n, value);
}
export fn __aeabi_memset8(dest: ?[*]u8, n: usize, value: c_int) void {
    __aeabi_memset(dest, n, value);
}
export fn __aeabi_memclr4(dest: ?[*]u8, n: usize) void {
    __aeabi_memclr(dest, n);
}
export fn __aeabi_memclr8(dest: ?[*]u8, n: usize) void {
    __aeabi_memclr(dest, n);
}

export fn __aeabi_unwind_cpp_pr0() void {}
export fn __aeabi_unwind_cpp_pr1() void {}

export fn Default_Handler() void {
    while (true) {}
}

const SCB_AIRCR: *volatile u32 = @ptrFromInt(0xE000_ED0C);

pub fn reset() noreturn {
    asm volatile ("dsb");
    SCB_AIRCR.* = 0x05FA_0004;
    while (true) {}
}

extern const _sidata: u8;
extern var _sdata: u8;
extern var _edata: u8;
extern var _sbss: u8;
extern var _ebss: u8;

fn initMemory() void {
    const data: [*]volatile u8 = @ptrCast(&_sdata);
    const load: [*]const u8 = @ptrCast(&_sidata);
    const data_len = @intFromPtr(&_edata) - @intFromPtr(&_sdata);
    for (0..data_len) |i| data[i] = load[i];

    const bss: [*]volatile u8 = @ptrCast(&_sbss);
    const bss_len = @intFromPtr(&_ebss) - @intFromPtr(&_sbss);
    for (0..bss_len) |i| bss[i] = 0;
}

export fn run() void {
    initMemory();
    chip.initCpu();
    @call(.never_inline, @import("root").app, .{});
}
