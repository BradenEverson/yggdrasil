//! Hardware Abstraction Layer of Fun and Happiness!!!

pub const gpio = @import("hal/gpio.zig");
pub const uart = @import("hal/uart.zig");
pub const i2c = @import("hal/i2c.zig");
pub const timer = @import("hal/timer.zig");

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
