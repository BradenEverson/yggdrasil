//! Root protocol implementation

const std = @import("std");

pub const Packet = @import("packet.zig");
pub const Opcode = Packet.Opcode;

/// Errors that are common to most APIs and
/// communication methods
pub const YggdrasilError = error{};

/// The middleware struct between a high level app layer
/// and whatever communication method there is at the
/// physical level (UART, LoRa, whateva)
pub const Yggdrasil = struct {
    /// A blocking consume function that reads
    /// a slice of bytes from a stream source
    /// (UART, LoRa, BLE, etc)
    read_bytes_fn: fn (buf: []u8) YggdrasilError![]u8,
    write_bytes_fn: fn (buf: []u8) YggdrasilError!void,

    buffer: []u8 = undefined,

    result_cb: fn (packet: Packet) void,

    building_packet: Packet = undefined,

    pub fn readStream(ygg: *Yggdrasil) YggdrasilError!void {
        const bytes = try ygg.read_bytes_fn(ygg.buffer);

        for (bytes) |byte| {
            // TODO: parse out through a state machine
            // once parse is complete and successful,
            // call the provided result_cb
            _ = byte;
        }
    }
};

test {
    _ = @import("packet.zig");
    _ = @import("message.zig");
}
