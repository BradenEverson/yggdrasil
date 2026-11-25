import math
import struct

VERSION = 1
UNKNOWN_SIGNAL = -128
EXTRAS_BIT = 0x80

_RECORD_HEADER = struct.Struct(">BBbbI")
_U16 = struct.Struct(">H")
_I16 = struct.Struct(">h")
_F32 = struct.Struct(">f")


def _quantize(x, lo, hi):
    if x is None or not math.isfinite(x):
        return None
    q = int(round(x))
    return q if lo <= q <= hi else None


def _gas_raw(ohm):
    if ohm is None or not ohm >= 1.0:
        return None
    return _quantize(math.log2(ohm) * 2048.0, 0, 0xFFFF)


FIELDS = [
    ("temperature_f", _I16,
     lambda f: _quantize((f - 32.0) * 5.0 / 9.0 * 100.0, -0x8000, 0x7FFF),
     lambda v: round(v / 100.0 * 9.0 / 5.0 + 32.0, 3)),
    ("pressure_hpa", _U16,
     lambda hpa: _quantize(hpa * 10.0, 0, 0xFFFF),
     lambda v: round(v / 10.0, 1)),
    ("humidity_pct", _U16,
     lambda pct: _quantize(pct * 100.0, 0, 0xFFFF),
     lambda v: round(v / 100.0, 2)),
    ("gas_ohm", _U16,
     _gas_raw,
     lambda v: round(2.0 ** (v / 2048.0), 3)),
]

_FIELD_BITS = {name: 1 << bit for bit, (name, _, _, _) in enumerate(FIELDS)}
_KNOWN_MASK = (1 << len(FIELDS)) - 1


def _signal(value):
    if value is None:
        return UNKNOWN_SIGNAL
    return max(-127, min(127, int(value)))


def _number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value)


def encode_record(record):
    readings = record["readings"]
    mask = 0
    body = bytearray()
    for bit, (name, packer, encode, _) in enumerate(FIELDS):
        value = _number(readings.get(name))
        raw = None if value is None else encode(value)
        if raw is not None:
            mask |= 1 << bit
            body += packer.pack(raw)

    extras = []
    for name, value in readings.items():
        value = _number(value)
        if value is None:
            continue
        if mask & _FIELD_BITS.get(name, 0):
            continue
        raw_name = name.encode()[:255]
        extras.append(bytes([len(raw_name)]) + raw_name + _F32.pack(value))
    extras = extras[:255]

    if extras:
        mask |= EXTRAS_BIT
        body.append(len(extras))
        for extra in extras:
            body += extra

    header = _RECORD_HEADER.pack(
        record["node"],
        record["via"],
        _signal(record["rssi"]),
        _signal(record["snr"]),
        max(0, int(record["time"])) & 0xFFFFFFFF,
    )
    return header + bytes([mask]) + bytes(body)


def encode_frame(encoded_records):
    return bytes([VERSION]) + b"".join(encoded_records)


def _take(data, i, n):
    if i + n > len(data):
        raise ValueError("truncated record")
    return data[i:i + n], i + n


def decode_frame(data):
    if not data:
        raise ValueError("empty frame")
    if data[0] != VERSION:
        raise ValueError(f"unsupported frame version {data[0]}")

    records = []
    i = 1
    while i < len(data):
        raw, i = _take(data, i, _RECORD_HEADER.size)
        node, via, rssi, snr, timestamp = _RECORD_HEADER.unpack(raw)
        raw, i = _take(data, i, 1)
        mask = raw[0]
        if mask & ~(_KNOWN_MASK | EXTRAS_BIT):
            raise ValueError(f"unknown field mask {mask:#04x}")

        readings = {}
        for bit, (name, packer, _, decode) in enumerate(FIELDS):
            if mask & (1 << bit):
                raw, i = _take(data, i, packer.size)
                (value,) = packer.unpack(raw)
                readings[name] = decode(value)

        if mask & EXTRAS_BIT:
            raw, i = _take(data, i, 1)
            for _ in range(raw[0]):
                raw, i = _take(data, i, 1)
                name, i = _take(data, i, raw[0])
                raw, i = _take(data, i, _F32.size)
                (value,) = _F32.unpack(raw)
                readings[name.decode(errors="replace")] = value

        records.append({
            "node": node,
            "via": via,
            "rssi": None if rssi == UNKNOWN_SIGNAL else rssi,
            "snr": None if snr == UNKNOWN_SIGNAL else snr,
            "time": timestamp,
            "readings": readings,
        })
    return records
