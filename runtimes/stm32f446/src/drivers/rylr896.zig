//! RYLR896 LoRA module API

const std = @import("std");
const hal = @import("../hal.zig");

uart: hal.uart.Uart,
rx_buffer: []u8,
tx_buffer: []u8,
timeout_ms: u32 = 2000,

const Self = @This();

pub const RylrError = error{
    NoEnter,
    HeadNotAT,
    NoEquals,
    UnknownCommand,
    TxOverTimes,
    RxOverTimes,
    CrcError,
    TxGreaterThan240,
    UnknownError,
    Timeout,
    BufferTooSmall,
};

pub fn reset(self: *Self) void {
    hal.uart.writeStr(self.uart, "AT+RESET\r\n");
}

fn readLine(self: *Self) RylrError![]u8 {
    const start = hal.timer.millis();
    var n: usize = 0;

    while (hal.timer.millis() -% start < self.timeout_ms) {
        const byte = hal.uart.tryReadByte(self.uart) orelse continue;
        if (n == self.rx_buffer.len) return RylrError.BufferTooSmall;

        self.rx_buffer[n] = byte;
        n += 1;
        if (byte == '\n') return self.rx_buffer[0..n];
    }
    return RylrError.Timeout;
}

fn send(self: *Self, msg: []const u8) RylrError!void {
    hal.uart.writeStr(self.uart, msg);

    const resp = try self.readLine();

    if (std.mem.startsWith(u8, resp, "+OK")) {
        return;
    }
    if (std.mem.startsWith(u8, resp, "+ERR=")) {
        const code_str = std.mem.trimEnd(u8, resp["+ERR=".len..], "\r\n");
        const code = std.fmt.parseInt(u8, code_str, 10) catch return RylrError.UnknownError;
        return switch (code) {
            1 => RylrError.NoEnter,
            2 => RylrError.HeadNotAT,
            3 => RylrError.NoEquals,
            4 => RylrError.UnknownCommand,
            10 => RylrError.TxOverTimes,
            11 => RylrError.RxOverTimes,
            12 => RylrError.CrcError,
            13 => RylrError.TxGreaterThan240,
            else => RylrError.UnknownError,
        };
    }
    return RylrError.UnknownError;
}

pub fn setNetwork(self: *Self, net: u16) RylrError!void {
    const msg = std.mem.print(
        self.tx_buffer,
        "AT+NETWORKID={}\r\n",
        .{net},
    ) catch return RylrError.BufferTooSmall;

    try self.send(msg);
}

pub fn setAddr(self: *Self, addr: u16) RylrError!void {
    const msg = std.mem.print(
        self.tx_buffer,
        "AT+ADDRESS={}\r\n",
        .{addr},
    ) catch return RylrError.BufferTooSmall;

    try self.send(msg);
}

pub fn sendString(self: *Self, to: u16, message: []const u8) RylrError!void {
    const msg = std.mem.print(
        self.tx_buffer,
        "AT+SEND={},{},{s}\r\n",
        .{ to, message.len, message },
    ) catch return RylrError.BufferTooSmall;

    try self.send(msg);
}

pub fn sendData(self: *Self, to: u16, data: []const u8) RylrError!void {
    const header = std.mem.print(
        self.tx_buffer,
        "AT+SEND={},{},",
        .{ to, data.len },
    ) catch return RylrError.BufferTooSmall;

    const total_len = header.len + data.len + 2;
    if (total_len > self.tx_buffer.len) return RylrError.BufferTooSmall;

    @memcpy(self.tx_buffer[header.len..][0..data.len], data);

    self.tx_buffer[header.len + data.len] = '\r';
    self.tx_buffer[header.len + data.len + 1] = '\n';

    try self.send(self.tx_buffer[0..total_len]);
}
