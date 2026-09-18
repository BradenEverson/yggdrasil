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

pub fn setNetwork(self: *Self, net: u16) !void {
    const msg = std.fmt.bufPrint(
        self.tx_buffer,
        "AT+NETWORKID={}\r\n",
        .{net},
    );

    _ = try idf.uart.writeBytes(self.port, msg);
}

pub fn setAddr(self: *Self, addr: u16) !void {
    const msg = std.fmt.bufPrint(
        self.tx_buffer,
        "AT+ADDRESS={}\r\n",
        .{addr},
    );

    _ = try idf.uart.writeBytes(self.port, msg);
}

pub fn sendData(self: *Self, to: u16, msg: []const u8) !void {
    const send = std.fmt.bufPrint(
        self.tx_buffer,
        "AT+SEND={},{},{s}\r\n",
        .{ to, msg.len, msg },
    );

    _ = try idf.uart.writeBytes(self.port, send);
}
