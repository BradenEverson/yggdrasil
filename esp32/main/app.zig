const std = @import("std");

const builtin = @import("builtin");
const idf = @import("esp_idf");
const ver = idf.ver.Version;
const sys = idf.sys;
const mem = std.mem;

const Rylr896 = @import("rylr896.zig");

const UART_PORT: c_uint = 1; // UART1
const BAUD_RATE = 115200;
const BUF_SIZE = 256;

const TX_PIN: c_int = 43;
const RX_PIN: c_int = 44;

const NETWORK_ID: u16 = 5;
const NODE_ADDR: u16 = 1;
const TARGET_ADDR: u16 = 2;
const HEARTBEAT_PERIOD_MS: u32 = 2000;

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

fn main() callconv(.c) void {
    var rx_buf: [BUF_SIZE]u8 = undefined;
    var tx_buf: [BUF_SIZE]u8 = undefined;

    var rylr896: Rylr896 = .{
        .port = UART_PORT,
        .rx_buffer = &rx_buf,
        .tx_buffer = &tx_buf,
    };

    var heap = idf.heap.HeapCapsAllocator.init(.{ .@"8bit" = true });
    var arena = std.heap.ArenaAllocator.init(heap.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();
    _ = allocator;

    log.info("Restarting LoRA Module", .{});

    const rst_bar = .@"41";
    idf.gpio.Direction.set(rst_bar, .output) catch unreachable;
    idf.gpio.Level.set(rst_bar, 0) catch unreachable;

    idf.rtos.Task.delayMs(100);

    idf.gpio.Level.set(rst_bar, 1) catch unreachable;

    idf.rtos.Task.delayMs(3500);

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

    rylr896.reset() catch {
        log.err("Reset command failed!!!", .{});
        unreachable;
    };

    idf.rtos.Task.delayMs(1000);

    log.info("Configuring network id={} addr={}", .{ NETWORK_ID, NODE_ADDR });

    rylr896.setNetwork(NETWORK_ID) catch {
        log.err("setNetwork failed!!!", .{});
        unreachable;
    };
    idf.rtos.Task.delayMs(200);

    rylr896.setAddr(NODE_ADDR) catch {
        log.err("setAddr failed!!!", .{});
        unreachable;
    };
    idf.rtos.Task.delayMs(1000);

    log.info("Node {} ready, heartbeating to {}", .{ NODE_ADDR, TARGET_ADDR });

    var heartbeat_count: u8 = 0;

    while (true) {
        heartbeat_count +%= 1;

        var msg_buf: [16]u8 = undefined;

        msg_buf[0] = @truncate(TARGET_ADDR >> 8);
        msg_buf[1] = @truncate(TARGET_ADDR);
        msg_buf[2] = '\r';
        msg_buf[3] = '\n';
        msg_buf[4] = heartbeat_count;

        const msg = msg_buf[0..5];

        rylr896.sendData(TARGET_ADDR, msg) catch |e| {
            log.err("send data failed: {any}", .{e});
            continue;
        };

        log.info("Sent: {x}", .{msg});
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
