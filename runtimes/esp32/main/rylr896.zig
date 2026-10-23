//! RYLR896 LoRA module API

const std = @import("std");
const idf = @import("esp_idf");

port: c_uint,
rx_buffer: []u8,
tx_buffer: []u8,

const Self = @This();

pub fn reset(self: *Self) !void {
    _ = try idf.uart.writeBytes(self.port, "AT+RESET\r\n");
}

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
};

fn send(self: *Self, msg: []const u8) !void {
    _ = try idf.uart.writeBytes(self.port, msg);

    const n = try idf.uart.readBytes(self.port, self.rx_buffer, 1000);
    const resp = self.rx_buffer[0..n];

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

pub fn setNetwork(self: *Self, net: u16) !void {
    const msg = try std.mem.print(
        self.tx_buffer,
        "AT+NETWORKID={}\r\n",
        .{net},
    );

    _ = try idf.uart.writeBytes(self.port, msg);
}

pub fn setAddr(self: *Self, addr: u16) !void {
    const msg = try std.mem.print(
        self.tx_buffer,
        "AT+ADDRESS={}\r\n",
        .{addr},
    );

    _ = try idf.uart.writeBytes(self.port, msg);
}

pub fn sendString(self: *Self, to: u16, message: []const u8) !void {
    const msg = try std.mem.print(
        self.tx_buffer,
        "AT+SEND={},{},{s}\r\n",
        .{ to, message.len, message },
    );

    try self.send(msg);
}

pub fn sendData(self: *Self, to: u16, data: []const u8) !void {
    const header = try std.mem.print(
        self.tx_buffer,
        "AT+SEND={},{},",
        .{ to, data.len },
    );

    const total_len = header.len + data.len + 2;
    if (total_len > self.tx_buffer.len) return error.BufferTooSmall;

    @memcpy(self.tx_buffer[header.len..][0..data.len], data);

    self.tx_buffer[header.len + data.len] = '\r';
    self.tx_buffer[header.len + data.len + 1] = '\n';

    try self.send(self.tx_buffer[0..total_len]);
}
