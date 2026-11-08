//! RYLR896 LoRA module API

const std = @import("std");
const hal = @import("../hal.zig");

uart: hal.uart.Uart,
rx_buffer: []u8,
tx_buffer: []u8,
timeout_ms: u32 = 5000,
line_state: LineState = .text,
line_len: usize = 0,
rcv_remaining: usize = 0,

inbox: [INBOX_SIZE]u8 = undefined,
inbox_head: u32 = 0,
inbox_tail: u32 = 0,
inbox_dropped: u32 = 0,

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

const INBOX_SIZE: u32 = 256;

const LineState = enum { text, rcv_addr, rcv_len, rcv_data, rcv_trailer };

const Response = union(enum) {
    ok,
    err: RylrError,
    other,
};

pub fn reset(self: *Self) void {
    self.line_state = .text;
    self.line_len = 0;
    hal.uart.writeStr(self.uart, "AT+RESET\r\n");
}

pub fn poll(self: *Self) void {
    while (self.inbox_head -% self.inbox_tail < INBOX_SIZE) {
        const byte = hal.uart.tryReadByte(self.uart) orelse break;
        _ = self.feed(byte);
    }
}

pub fn read(self: *Self, buf: []u8) []u8 {
    self.poll();

    var n: usize = 0;
    while (n < buf.len and self.inbox_head != self.inbox_tail) : (n += 1) {
        buf[n] = self.inbox[self.inbox_tail % INBOX_SIZE];
        self.inbox_tail +%= 1;
    }

    return buf[0..n];
}

fn pushInbox(self: *Self, byte: u8) void {
    if (self.inbox_head -% self.inbox_tail >= INBOX_SIZE) {
        self.inbox_dropped +%= 1;
        return;
    }

    self.inbox[self.inbox_head % INBOX_SIZE] = byte;
    self.inbox_head +%= 1;
}

fn feed(self: *Self, byte: u8) ?Response {
    switch (self.line_state) {
        .text => {
            if (self.line_len < self.rx_buffer.len) {
                self.rx_buffer[self.line_len] = byte;
                self.line_len += 1;
            }

            if (self.line_len == "+RCV=".len and std.mem.eql(u8, self.rx_buffer[0..self.line_len], "+RCV=")) {
                self.line_state = .rcv_addr;
                self.line_len = 0;
                return null;
            }

            if (byte == '\n') {
                const line = self.rx_buffer[0..self.line_len];
                self.line_len = 0;
                return classify(line);
            }
        },
        .rcv_addr => {
            if (byte == ',') {
                self.line_state = .rcv_len;
                self.rcv_remaining = 0;
            }
        },
        .rcv_len => {
            if (byte == ',') {
                self.line_state = if (self.rcv_remaining == 0) .rcv_trailer else .rcv_data;
            } else if (byte >= '0' and byte <= '9' and self.rcv_remaining < 1000) {
                self.rcv_remaining = self.rcv_remaining * 10 + (byte - '0');
            } else {
                self.line_state = if (byte == '\n') .text else .rcv_trailer;
            }
        },
        .rcv_data => {
            self.pushInbox(byte);
            self.rcv_remaining -= 1;
            if (self.rcv_remaining == 0)
                self.line_state = .rcv_trailer;
        },
        .rcv_trailer => {
            if (byte == '\n')
                self.line_state = .text;
        },
    }

    return null;
}

fn classify(line: []const u8) Response {
    if (std.mem.startsWith(u8, line, "+OK"))
        return .ok;

    if (std.mem.startsWith(u8, line, "+ERR=")) {
        const code_str = std.mem.trimEnd(u8, line["+ERR=".len..], "\r\n");
        const code = std.fmt.parseInt(u8, code_str, 10) catch return .{ .err = RylrError.UnknownError };
        return .{ .err = switch (code) {
            1 => RylrError.NoEnter,
            2 => RylrError.HeadNotAT,
            3 => RylrError.NoEquals,
            4 => RylrError.UnknownCommand,
            10 => RylrError.TxOverTimes,
            11 => RylrError.RxOverTimes,
            12 => RylrError.CrcError,
            13 => RylrError.TxGreaterThan240,
            else => RylrError.UnknownError,
        } };
    }

    return .other;
}

fn send(self: *Self, msg: []const u8) RylrError!void {
    self.poll();
    hal.uart.writeStr(self.uart, msg);

    const start = hal.timer.millis();
    while (hal.timer.millis() -% start < self.timeout_ms) {
        const byte = hal.uart.tryReadByte(self.uart) orelse continue;
        switch (self.feed(byte) orelse continue) {
            .ok => return,
            .err => |e| return e,
            .other => {},
        }
    }

    return RylrError.Timeout;
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
