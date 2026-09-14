const std = @import("std");

const builtin = @import("builtin");
const idf = @import("esp_idf");
const ver = idf.ver.Version;
const sys = idf.sys;
const mem = std.mem;

const UART_PORT: c_uint = 1; // UART1
const BAUD_RATE = 115200;
const BUF_SIZE = 256;

const TX_PIN: c_int = 43;
const RX_PIN: c_int = 44;

comptime {
    @export(&main, .{ .name = "app_main" });
}

pub fn setPin(port: c_uint, pins: struct {
    tx: c_int = sys.UART_PIN_NO_CHANGE,
    rx: c_int = sys.UART_PIN_NO_CHANGE,
    rts: c_int = sys.UART_PIN_NO_CHANGE,
    cts: c_int = sys.UART_PIN_NO_CHANGE,
}) !void {
    const ret = sys._uart_set_pin4(
        port,
        pins.tx,
        pins.rx,
        pins.rts,
        pins.cts,
    );
    if (ret != sys.ESP_OK) return error.SetPinFailed;
}

var rx_buf: [64]u8 = undefined;
var tx_buf: [64]u8 = undefined;

fn main() callconv(.c) void {
    var heap = idf.heap.HeapCapsAllocator.init(.{ .@"8bit" = true });
    var arena = std.heap.ArenaAllocator.init(heap.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();
    _ = allocator;

    log.info("Let's Mesh This Network", .{});

    idf.uart.driverInstall(UART_PORT, .{
        .rx_buffer_size = BUF_SIZE * 2,
        .tx_buffer_size = 0,
    }) catch unreachable;

    idf.uart.setBaudrate(UART_PORT, BAUD_RATE) catch unreachable;
    idf.uart.setWordLength(UART_PORT, idf.sys.UART_DATA_8_BITS) catch unreachable;
    idf.uart.setParity(UART_PORT, idf.sys.UART_PARITY_DISABLE) catch unreachable;
    idf.uart.setStopBits(UART_PORT, idf.sys.UART_STOP_BITS_1) catch unreachable;

    setPin(UART_PORT, .{
        .tx = TX_PIN,
        .rx = RX_PIN,
    }) catch unreachable;

    log.info("UART ready", .{});

    tx_buf[0] = 'h';
    tx_buf[1] = 'e';
    tx_buf[2] = 'l';
    tx_buf[3] = 'l';
    tx_buf[4] = 'o';

    _ = idf.uart.writeBytes(UART_PORT, tx_buf[0..5]) catch {
        log.err("Write failed!!!", .{});
        unreachable;
    };

    const n = idf.uart.readBytes(UART_PORT, &rx_buf, 0) catch {
        log.err("Read failed!!!", .{});
        unreachable;
    };
    log.info("{s}", .{rx_buf[0..n]});

    while (true) {
        idf.rtos.Task.delayMs(100);
    }
}

const log = std.log.scoped(.yggdrasil);

pub const panic = idf.esp_panic.panic;
pub const std_options: std.Options = .{
    .page_size_min = 4096,
    .page_size_max = 4096,

    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        else => .info,
    },
    .logFn = idf.log.espLogFn,
};
