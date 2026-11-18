import ctypes
import os
import struct
import time

BROADCAST_ADDR = 0xFF
MAX_ADDRESS = 0xFE

PRIORITY_HIGH = 0
PRIORITY_LOW = 10

# AppPacket.Opcode
OP_HELLO = 0
OP_IM_A_ROOT = 1
OP_CONFIGURE_STREAM = 2
OP_TOPOLOGY_INFO = 3
OP_SENSOR_READINGS = 4
OP_COMPACT_READINGS = 5
OP_BATCHED_READINGS = 6
OP_READING_SERIES = 7

_VALUE_FORMATS = ["B", "H", "I", "Q", "b", "h", "i", "q", "f", "d"]
_FLOAT32 = _VALUE_FORMATS.index("f")

_COMPACT_FIELDS = [
    ("t", ">h", lambda v: v / 100.0 * 9.0 / 5.0 + 32.0),
    ("p", ">H", lambda v: v / 10.0),
    ("h", ">H", lambda v: v / 100.0),
    ("g", ">H", lambda v: 2.0 ** (v / 2048.0)),
]

_WRITE_CB = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.POINTER(ctypes.c_uint8), ctypes.c_size_t)
_PACKET_CB = ctypes.CFUNCTYPE(
    None,
    ctypes.c_uint8,
    ctypes.c_uint8,
    ctypes.c_uint8,
    ctypes.c_bool,
    ctypes.POINTER(ctypes.c_uint8),
    ctypes.c_size_t,
)
_LOST_CB = ctypes.CFUNCTYPE(None, ctypes.c_uint8)


def _find_library():
    here = os.path.dirname(os.path.abspath(__file__))
    candidates = [
        os.environ.get("YGGDRASIL_LIB"),
        os.path.join(here, "libyggdrasil.so"),
        os.path.join(here, "..", "yggdrasil", "zig-out", "lib", "libyggdrasil.so"),
    ]
    for path in candidates:
        if path and os.path.exists(path):
            return path
    raise OSError(
        "libyggdrasil.so not found; build it with `zig build clib` in yggdrasil/ "
        "or set YGGDRASIL_LIB"
    )


def _load(path):
    lib = ctypes.CDLL(path)
    lib.ygg_init.argtypes = [ctypes.c_uint8, ctypes.c_bool, _WRITE_CB, _PACKET_CB, _LOST_CB]
    lib.ygg_init.restype = None
    lib.ygg_configure_power.argtypes = [ctypes.c_uint32, ctypes.c_uint8, ctypes.c_uint32, ctypes.c_uint8, ctypes.c_uint8]
    lib.ygg_configure_power.restype = None
    lib.ygg_set_root_beacon.argtypes = [ctypes.c_uint32]
    lib.ygg_set_root_beacon.restype = None
    lib.ygg_set_max_children.argtypes = [ctypes.c_uint32]
    lib.ygg_set_max_children.restype = None
    lib.ygg_set_root_seq.argtypes = [ctypes.c_uint16]
    lib.ygg_set_root_seq.restype = None
    lib.ygg_idle_for.argtypes = []
    lib.ygg_idle_for.restype = ctypes.c_uint32
    lib.ygg_set_time.argtypes = [ctypes.c_uint32]
    lib.ygg_set_time.restype = None
    lib.ygg_feed.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
    lib.ygg_feed.restype = ctypes.c_int
    lib.ygg_request_write.argtypes = []
    lib.ygg_request_write.restype = ctypes.c_int
    lib.ygg_say_hello.argtypes = []
    lib.ygg_say_hello.restype = ctypes.c_int
    lib.ygg_announce_root.argtypes = []
    lib.ygg_announce_root.restype = None
    lib.ygg_announce_topology.argtypes = []
    lib.ygg_announce_topology.restype = None
    lib.ygg_root_address.argtypes = []
    lib.ygg_root_address.restype = ctypes.c_int32
    lib.ygg_send.argtypes = [ctypes.c_uint8, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_uint8]
    lib.ygg_send.restype = ctypes.c_int
    lib.ygg_neighbor_count.argtypes = []
    lib.ygg_neighbor_count.restype = ctypes.c_uint32
    lib.ygg_neighbor.argtypes = [ctypes.c_uint32]
    lib.ygg_neighbor.restype = ctypes.c_int32
    return lib


class Node(object):
    def __init__(self, address, write, on_packet=None, on_neighbor_lost=None,
                 is_root=False, lib_path=None):
        self._lib = _load(lib_path or _find_library())
        self._write = write
        self.on_packet = on_packet
        self.on_neighbor_lost = on_neighbor_lost
        self._t0 = time.monotonic()
        if not 0 <= address <= MAX_ADDRESS:
            raise ValueError(f"address must be 0-{MAX_ADDRESS}, got {address}")

        self._write_cb = _WRITE_CB(self._c_write)
        self._packet_cb = _PACKET_CB(self._c_packet)
        self._lost_cb = _LOST_CB(self._c_lost)

        self.tick()
        self._lib.ygg_init(address, is_root, self._write_cb, self._packet_cb, self._lost_cb)

    def _c_write(self, ptr, length):
        try:
            return 0 if self._write(ctypes.string_at(ptr, length)) else 1
        except Exception as e:
            print(f"write callback error: {e}")
            return 1

    def _c_packet(self, origin, from_addr, dest, broadcast, ptr, length):
        if not self.on_packet:
            return
        try:
            self.on_packet(origin, from_addr, dest, broadcast, ctypes.string_at(ptr, length))
        except Exception as e:
            print(f"packet callback error: {e}")

    def _c_lost(self, addr):
        if self.on_neighbor_lost:
            try:
                self.on_neighbor_lost(addr)
            except Exception as e:
                print(f"neighbor lost callback error: {e}")

    def tick(self):
        ms = int((time.monotonic() - self._t0) * 1000) & 0xFFFFFFFF
        self._lib.ygg_set_time(ms)

    def configure_power(self, period_ms, spreading_factor, bandwidth_hz, coding_rate, preamble):
        self._lib.ygg_configure_power(period_ms, spreading_factor, bandwidth_hz, coding_rate, preamble)

    def set_root_beacon(self, period_ms):
        self._lib.ygg_set_root_beacon(period_ms)

    def set_max_children(self, max_children):
        self._lib.ygg_set_max_children(max_children)

    def set_root_seq(self, seq):
        self._lib.ygg_set_root_seq(seq & 0xFFFF)

    def idle_for(self):
        return self._lib.ygg_idle_for()

    def feed(self, data):
        self._lib.ygg_feed(data, len(data))

    def request_write(self):
        return self._lib.ygg_request_write() == 1

    def say_hello(self):
        return self._lib.ygg_say_hello() == 0

    def announce_root(self):
        self._lib.ygg_announce_root()

    def announce_topology(self):
        self._lib.ygg_announce_topology()

    def root_address(self):
        r = self._lib.ygg_root_address()
        return None if r < 0 else r

    def send(self, dest, payload, priority=PRIORITY_LOW):
        return self._lib.ygg_send(dest, payload, len(payload), priority)

    def neighbors(self):
        return [self._lib.ygg_neighbor(i) for i in range(self._lib.ygg_neighbor_count())]


def parse_app_packet(body):
    if not body:
        return None
    return body[0], body[1:]


def parse_sensor_readings(payload):
    readings = []
    i = 0
    while i + 2 <= len(payload):
        entry_len = payload[i]
        entry = payload[i + 1:i + 1 + entry_len]
        if len(entry) < entry_len or entry[0] >= len(_VALUE_FORMATS):
            break
        fmt = ">" + _VALUE_FORMATS[entry[0]]
        size = struct.calcsize(fmt)
        name_len = entry_len - 1 - size
        if name_len < 0:
            break
        name = entry[1:1 + name_len].decode(errors="replace")
        (value,) = struct.unpack(fmt, entry[1 + name_len:1 + name_len + size])
        readings.append((name, value))
        i += 1 + entry_len
    return readings


def _compact_len(mask):
    if mask >> len(_COMPACT_FIELDS):
        return None
    return 1 + 2 * bin(mask).count("1")


def parse_compact_readings(payload):
    if not payload:
        return []
    mask = payload[0]
    if len(payload) != _compact_len(mask):
        return []
    readings = []
    i = 1
    for bit, (name, fmt, decode) in enumerate(_COMPACT_FIELDS):
        if mask & (1 << bit):
            (raw,) = struct.unpack(fmt, payload[i:i + 2])
            readings.append((name, decode(raw)))
            i += 2
    return readings


def encode_sensor_readings(readings):
    out = bytearray()
    for name, value in readings:
        raw = name.encode()
        out.append(1 + len(raw) + 4)
        out.append(_FLOAT32)
        out += raw
        out += struct.pack(">f", value)
    return bytes(out)


def parse_batched_readings(payload):
    entries = []
    i = 0
    while i < len(payload):
        if i + 2 > len(payload):
            return []
        size = _compact_len(payload[i + 1])
        if size is None or i + 1 + size > len(payload):
            return []
        readings = parse_compact_readings(payload[i + 1:i + 1 + size])
        if not readings:
            return []
        entries.append((payload[i], readings))
        i += 1 + size
    return entries


_SERIES_HEADER_LEN = 6
_SERIES_INTERVAL_UNIT_S = 10
_SERIES_ESCAPE = 0x80


def parse_reading_series(payload):
    records = []
    i = 0
    while i < len(payload):
        if i + _SERIES_HEADER_LEN > len(payload):
            return []
        origin, mask, count, interval = payload[i], payload[i + 1], payload[i + 2], payload[i + 3]
        if mask == 0 or mask >> len(_COMPACT_FIELDS) or count == 0:
            return []
        age_s = int.from_bytes(payload[i + 4:i + 6], "big")
        interval_s = interval * _SERIES_INTERVAL_UNIT_S
        fields = [(bit, field) for bit, field in enumerate(_COMPACT_FIELDS) if mask & (1 << bit)]
        i += _SERIES_HEADER_LEN
        values = [0] * len(fields)
        samples = []
        for index in range(count):
            for slot in range(len(fields)):
                if index == 0 or payload[i] == _SERIES_ESCAPE:
                    if index != 0:
                        i += 1
                    if i + 2 > len(payload):
                        return []
                    values[slot] = int.from_bytes(payload[i:i + 2], "big")
                    i += 2
                else:
                    delta = payload[i] - 256 if payload[i] > 127 else payload[i]
                    values[slot] = (values[slot] + delta) & 0xFFFF
                    i += 1
                if i > len(payload):
                    return []
            readings = []
            for (bit, (name, fmt, decode)), raw in zip(fields, values):
                (value,) = struct.unpack(fmt, raw.to_bytes(2, "big"))
                readings.append((name, decode(value)))
            samples.append((age_s + (count - 1 - index) * interval_s, readings))
        records.append((origin, samples))
    return records
