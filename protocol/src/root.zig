//! Root protocol implementation

const std = @import("std");

pub const Packet = @import("packet.zig");
pub const Opcode = Packet.Opcode;

pub const PacketStreamParser = struct {
    /// A blocking consume function that reads
    /// a slice of bytes from a stream source
    /// (UART, LoRa, BLE, etc)
    consume_bytes_fn: fn (buf: []u8) []u8,
    buffer: []u8 = undefined,

    result_cb: fn (packet: Packet) void,

    building_packet: Packet = undefined,

    pub fn readStream(psp: *PacketStreamParser) void {
        const bytes = psp.consume_bytes_fn(psp.buffer);

        for (bytes) |byte| {
            // TODO: parse out through a state machine
            // once parse is complete and successful,
            // call the provided result_cb
            _ = byte;
        }
    }
};
