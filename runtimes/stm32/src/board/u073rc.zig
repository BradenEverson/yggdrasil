const hal = @import("../hal.zig");
const Pin = hal.gpio.Pin;

pub const sysclk_hz: u32 = 16_000_000;

pub const debug_uart: hal.uart.Uart = .usart2;
pub const debug_tx: Pin = .{ .port = .a, .num = 2 };
pub const debug_rx: Pin = .{ .port = .a, .num = 3 };

pub const lora_uart: hal.uart.Uart = .usart1;
pub const lora_tx: Pin = .{ .port = .a, .num = 9 };
pub const lora_rx: Pin = .{ .port = .a, .num = 10 };

pub const sensor_i2c: hal.i2c.I2c = .i2c1;
pub const sensor_scl: Pin = .{ .port = .b, .num = 8 };
pub const sensor_sda: Pin = .{ .port = .b, .num = 9 };

pub const swd_pins = [_]Pin{
    .{ .port = .a, .num = 13 },
    .{ .port = .a, .num = 14 },
};
