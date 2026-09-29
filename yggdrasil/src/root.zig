//! Root protocol implementation

const std = @import("std");

pub const NetworkPacket = @import("network_packet.zig");
pub const AppPacket = @import("app_packet.zig");

/// Errors that are common to most APIs and
/// communication methods
pub const YggdrasilError = error{};
const LARGEST_PACKET_SIZE: usize = 240;

const NETWORK_HEADER_LEN: usize = 12;

/// The states we can be in while reading
/// from the incoming stream
pub const ParseState = enum {
    awaiting_header,

    awaiting_from_msb,
    awaiting_from_lsb,

    awaiting_to_msb,
    awaiting_to_lsb,

    awaiting_sn_msb,
    awaiting_sn_lsb,

    awaiting_flags,

    awaiting_len_msb,
    awaiting_len_lsb,

    reading_payload,

    awaiting_crc_msb,
    awaiting_crc_lsb,
};

/// The middleware struct between a high level app layer
/// and whatever communication method there is at the
/// physical level (UART, LoRa, whateva)
pub const Yggdrasil = struct {
    /// A blocking consume function that reads
    /// a slice of bytes from a stream source
    /// (UART, LoRa, BLE, etc)
    read_bytes_fn: *const fn (buf: []u8) YggdrasilError![]u8,
    write_bytes_fn: *const fn (buf: []u8) YggdrasilError!void,

    state: ParseState = .awaiting_header,
    cursor: usize = 0,

    buffer: []u8 = undefined,
    packet_buffer: [LARGEST_PACKET_SIZE]u8 = undefined,

    result_cb: *const fn (packet: NetworkPacket) void,

    building_packet: NetworkPacket = .{},

    pub fn readStream(ygg: *Yggdrasil) YggdrasilError!void {
        const bytes = try ygg.read_bytes_fn(ygg.buffer);

        for (bytes) |byte| {
            if (ygg.readByte(byte)) |packet| {
                if (NetworkPacket.CRC.validateCRC(
                    ygg.packet_buffer[0 .. ygg.building_packet.payload.len + NETWORK_HEADER_LEN - 2],
                    ygg.building_packet.crc.?,
                )) {
                    ygg.result_cb(packet);
                } else {
                    // Call error callback!
                    // The application from here can choose
                    // to send a nack, shouldn't be our decision
                    // here
                    if (ygg.failure_cb) |failure_cb|
                        failure_cb(.checksum_mismatch);
                }
            }
        }
    }

    pub fn readByte(ygg: *Yggdrasil, byte: u8) ?NetworkPacket {
        ygg.packet_buffer[ygg.cursor] = byte;
        ygg.cursor += 1;

        switch (ygg.state) {
            .awaiting_header => {
                if (byte == NetworkPacket.HEADER) {
                    ygg.state = .awaiting_from_msb;
                }
            },

            .awaiting_from_msb => {
                ygg.building_packet.from = 0;
                ygg.building_packet.from |= byte;
                ygg.building_packet.from <<= 8;
                ygg.state = .awaiting_from_lsb;
            },
            .awaiting_from_lsb => {
                ygg.building_packet.from |= byte;
                ygg.state = .awaiting_to_msb;
            },

            .awaiting_to_msb => {
                ygg.building_packet.to = 0;
                ygg.building_packet.to |= byte;
                ygg.building_packet.to <<= 8;
                ygg.state = .awaiting_to_lsb;
            },
            .awaiting_to_lsb => {
                ygg.building_packet.to |= byte;
                ygg.state = .awaiting_sn_msb;
            },

            .awaiting_sn_msb => {
                ygg.building_packet.sn = 0;
                ygg.building_packet.sn |= byte;
                ygg.building_packet.sn <<= 8;
                ygg.state = .awaiting_sn_lsb;
            },
            .awaiting_sn_lsb => {
                ygg.building_packet.sn |= byte;
                ygg.state = .awaiting_flags;
            },

            .awaiting_flags => {
                ygg.building_packet.parseFlags(byte);
                ygg.state = .awaiting_len_msb;
            },

            .awaiting_len_msb => {
                ygg.building_packet.len = 0;
                ygg.building_packet.len |= byte;
                ygg.building_packet.len <<= 8;
                ygg.state = .awaiting_len_lsb;
            },
            .awaiting_len_lsb => {
                ygg.building_packet.len |= byte;

                if (ygg.building_packet.len == 0) {
                    ygg.building_packet.payload = ygg.packet_buffer[NETWORK_HEADER_LEN..NETWORK_HEADER_LEN];
                    ygg.state = .awaiting_crc_msb;
                } else {
                    ygg.state = .reading_payload;
                }
            },
            .reading_payload => {
                if (ygg.cursor == ygg.building_packet.len + NETWORK_HEADER_LEN) {
                    ygg.building_packet.payload = ygg.packet_buffer[NETWORK_HEADER_LEN .. NETWORK_HEADER_LEN + ygg.building_packet.len];
                    ygg.state = .awaiting_crc_msb;
                }
            },

            .awaiting_crc_msb => {
                ygg.building_packet.crc = 0;
                ygg.building_packet.crc.? |= byte;
                ygg.building_packet.crc.? <<= 8;
                ygg.state = .awaiting_crc_lsb;
            },
            .awaiting_crc_lsb => {
                ygg.building_packet.crc.? |= byte;

                ygg.state = .awaiting_header;
                ygg.cursor = 0;
                return ygg.building_packet;
            },
        }

        return null;
    }
};

test {
    _ = @import("network_packet.zig");
    _ = @import("app_packet.zig");
}

fn nopRead(buf: []u8) YggdrasilError![]u8 {
    const nop = [12]u8{
        0x72,

        0x00,
        0x01,

        0x00,
        0x02,

        0x00,
        0x01,

        0b1100_0000,

        0x00,
        0x00,

        0x2C,
        0xD8,
    };

    buf[0] = nop[0];
    buf[1] = nop[1];
    buf[2] = nop[2];
    buf[3] = nop[3];
    buf[4] = nop[4];
    buf[5] = nop[5];
    buf[6] = nop[6];
    buf[7] = nop[7];
    buf[8] = nop[8];
    buf[9] = nop[9];
    buf[10] = nop[10];
    buf[11] = nop[11];

    return buf[0..12];
}

fn emptyWrite(buf: []u8) YggdrasilError!void {
    _ = buf;
}

fn yay(packet: NetworkPacket) void {
    std.debug.print("{any}\n", .{packet});
}

test "Simple packet parsing" {
    var buffer: [64]u8 = undefined;

    var ygg = Yggdrasil{
        .read_bytes_fn = nopRead,
        .write_bytes_fn = emptyWrite,
        .result_cb = yay,
        .buffer = &buffer,
    };

    try ygg.readStream();
}
