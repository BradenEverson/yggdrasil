import argparse
import csv
import os
import random
import select
import struct
import time
import websocket
from datetime import datetime

import yggdrasil
from rylr896 import RYLR896

NETWORK_ID = 5
RADIO_BROADCAST_ADDR = 0
ROOT_ANNOUNCE_PERIOD_S = 15 * 60.0
ROOT_ANNOUNCE_JITTER_S = 30.0
LOOP_SLEEP_S = 0.005
RADIO_CHECK_PERIOD_S = 60.0
WS_CONNECT_TIMEOUT_S = 3.0
WS_RECONNECT_PERIOD_S = 10.0
ROOT_BEACON_MS = 20_000
MAX_CHILDREN = 0

BANDWIDTH_CODES = {
    7800: 0,
    10400: 1,
    15600: 2,
    20800: 3,
    31250: 4,
    41700: 5,
    62500: 6,
    125000: 7,
    250000: 8,
    500000: 9,
}

KNOWN_READINGS = {
    "t": "temperature_f",
    "p": "pressure_hpa",
    "h": "humidity_pct",
    "g": "gas_ohm",
}

CSV_FIELDS = [
    "timestamp",
    "node_address",
    "via",
    "rssi",
    "snr",
    "temperature_f",
    "pressure_hpa",
    "humidity_pct",
    "gas_ohm",
    "extra",
]


class CsvLog(object):
    def __init__(self, path):
        needs_header = not os.path.exists(path) or os.path.getsize(path) == 0
        self.file = open(path, "a", newline="")
        self.writer = csv.DictWriter(self.file, fieldnames=CSV_FIELDS)
        if needs_header:
            self.writer.writeheader()
            self.flush()

    def write(self, row):
        self.writer.writerow(row)
        self.flush()

    def flush(self):
        self.file.flush()
        os.fsync(self.file.fileno())

    def close(self):
        self.file.close()


class WebSocketStream(object):
    def __init__(self, url):
        self._websocket = websocket
        self.url = url
        self.ws = None
        self.next_attempt = 0.0
        self.connect()

    def connect(self):
        now = time.monotonic()
        if now < self.next_attempt:
            return False
        self.next_attempt = now + WS_RECONNECT_PERIOD_S
        try:
            self.ws = self._websocket.create_connection(self.url, timeout=WS_CONNECT_TIMEOUT_S)
            print(f"Connected to {self.url}")
            return True
        except Exception as e:
            print(f"Websocket connect to {self.url} failed: {e}")
            self.ws = None
            return False

    def drop(self, reason):
        print(f"Websocket {self.url} disconnected: {reason}")
        try:
            self.ws.close(timeout=0.5)
        except Exception:
            pass
        self.ws = None
        self.next_attempt = 0.0

    def send(self, payload):
        if self.ws is None and not self.connect():
            print("Websocket unavailable, dropping reading")
            return False
        try:
            self.ws.send_binary(payload)
            return True
        except Exception as e:
            self.drop(e)
            print("Dropped reading")
            return False

    def poll(self):
        if self.ws is None:
            return
        try:
            while select.select([self.ws.sock], [], [], 0)[0]:
                opcode, _ = self.ws.recv_data_frame(control_frame=True)
                if opcode == self._websocket.ABNF.OPCODE_CLOSE:
                    self.drop("closed by server")
                    return
        except Exception as e:
            self.drop(e)

    def close(self):
        if self.ws is not None:
            try:
                self.ws.close(timeout=0.5)
            except Exception:
                pass
            self.ws = None


def describe_frame(frame):
    if len(frame) < 4:
        return f"(not a frame, {len(frame)} bytes)"
    flags, src, dst, hops = frame[0], frame[1], frame[2], frame[3]
    i = 4
    origin, dest, ttl, wake, period = src, dst, None, None, None
    if flags & 0x08:
        origin = frame[i] if i < len(frame) else None
        i += 1
    if flags & 0x04:
        dest, ttl = (frame[i], frame[i + 1]) if i + 1 < len(frame) else (None, None)
        i += 2
    if flags & 0x02:
        wake = int.from_bytes(frame[i:i + 2], "big") / 65536.0 if i + 1 < len(frame) else None
        i += 2
    if flags & 0x01:
        period = int.from_bytes(frame[i:i + 2], "big") * 100 if i + 1 < len(frame) else None
        i += 2
    if i > len(frame):
        return f"(truncated frame, {len(frame)} bytes)"
    names = [n for b, n in ((0x80, "ack"), (0x40, "bcast"), (0x20, "sn"), (0x10, "nesn")) if flags & b]
    op = frame[i] if i < len(frame) else None
    route = f" {origin}=>{dest} ttl={ttl}" if (origin, dest) != (src, dst) or ttl is not None else ""
    sched = "" if wake is None else f" wake={wake:.3f}" + ("" if period is None else f" period={period}")
    return f"{src}>{dst}{route} len={len(frame) - i} op={op} hops={hops}{sched} [{','.join(names)}]"


class Hub(object):
    def __init__(self, radio, log, stream, address, sf, bandwidth_hz, coding_rate, preamble, tx_power, trace=False, max_children=MAX_CHILDREN):
        self.trace = trace
        self.radio = radio
        self.stream = stream
        self.parameter = f"{sf},{BANDWIDTH_CODES[bandwidth_hz]},{coding_rate},{preamble}"
        self.tx_power = tx_power
        self.seen_resets = radio.resets
        self.log = log
        self.last_rssi = None
        self.last_snr = None
        self.node = yggdrasil.Node(
            address,
            write=self.transmit,
            on_packet=self.on_packet,
            on_neighbor_lost=lambda addr: print(f"Lost neighbor {addr}"),
            is_root=True,
        )
        self.node.configure_power(0, sf, bandwidth_hz, coding_rate, preamble)
        self.node.set_root_seq(int(time.time() // 60))
        self.node.set_root_beacon(ROOT_BEACON_MS)
        self.node.set_max_children(max_children)

    def check_radio(self):
        resets = self.radio.resets
        current = self.radio.query_parameter()
        if current == self.parameter and resets == self.seen_resets:
            return

        print(f"Radio drifted (parameter={current}, resets={resets - self.seen_resets}), restoring {self.parameter}")
        self.seen_resets = resets
        if not self.radio.command(f"AT+PARAMETER={self.parameter}"):
            print("Failed to restore AT+PARAMETER")
        if not self.radio.command(f"AT+CRFOP={self.tx_power}"):
            print("Failed to restore AT+CRFOP")

    def transmit(self, frame):
        ok = self.radio.send_data(RADIO_BROADCAST_ADDR, frame)
        if self.trace:
            print(f"{time.monotonic():.3f} tx {describe_frame(frame)} ok={ok}")
        return ok

    def on_radio(self, message):
        self.last_rssi = message["rssi"]
        self.last_snr = message["snr"]
        if self.trace:
            print(f"{time.monotonic():.3f} rx {describe_frame(message['data'])} rssi={message['rssi']} snr={message['snr']}")
        self.node.tick()
        self.node.feed(message["data"])

    def on_packet(self, origin, from_addr, dest, broadcast, body):
        app = yggdrasil.parse_app_packet(body)
        if app is None:
            return
        op, payload = app

        if op == yggdrasil.OP_SENSOR_READINGS and not broadcast:
            self.on_readings(origin, from_addr, yggdrasil.parse_sensor_readings(payload), bytes(payload))
        elif op == yggdrasil.OP_COMPACT_READINGS and not broadcast:
            readings = yggdrasil.parse_compact_readings(payload)
            self.on_readings(origin, from_addr, readings, yggdrasil.encode_sensor_readings(readings))
        elif op == yggdrasil.OP_BATCHED_READINGS and not broadcast:
            entries = yggdrasil.parse_batched_readings(payload)
            if not entries:
                print(f"Malformed batch from Node {origin} (via {from_addr})")
            for entry_origin, readings in entries:
                self.on_readings(entry_origin, from_addr, readings, yggdrasil.encode_sensor_readings(readings))
        elif op == yggdrasil.OP_HELLO and broadcast:
            print(f"Hello from {from_addr}")

    def on_readings(self, origin, from_addr, readings, wire):
        if not readings:
            print(f"Malformed readings from Node {origin} (via {from_addr})")
            return
        pretty = "  ".join(f"{n}={v:.2f}" if isinstance(v, float) else f"{n}={v}" for n, v in readings)
        print(f"From Node {origin} (via {from_addr}, rssi {self.last_rssi}): {pretty}")

        if self.stream is not None:
            self.stream.send(struct.pack(">H", origin) + wire)
            return

        row = {
            "timestamp": datetime.now().isoformat(timespec="seconds"),
            "node_address": origin,
            "via": from_addr,
            "rssi": self.last_rssi,
            "snr": self.last_snr,
        }
        extra = []
        for name, value in readings:
            if isinstance(value, float):
                value = round(value, 3)
            column = KNOWN_READINGS.get(name)
            if column:
                row[column] = value
            else:
                extra.append(f"{name}={value}")
        row["extra"] = ";".join(extra)
        self.log.write(row)

    @staticmethod
    def announce_delay():
        return ROOT_ANNOUNCE_PERIOD_S + random.uniform(-ROOT_ANNOUNCE_JITTER_S, ROOT_ANNOUNCE_JITTER_S)

    def run(self):
        self.node.tick()
        self.node.announce_root()

        next_announce = time.monotonic() + self.announce_delay()
        next_radio_check = time.monotonic()
        known_neighbors = []

        print("Hub running...")
        while True:
            self.node.tick()
            self.radio.poll()
            if self.stream is not None:
                self.stream.poll()

            now = time.monotonic()
            if now >= next_radio_check or self.radio.resets != self.seen_resets:
                self.check_radio()
                next_radio_check = time.monotonic() + RADIO_CHECK_PERIOD_S

            if now >= next_announce:
                self.node.announce_root()
                next_announce = now + self.announce_delay()

            self.node.tick()
            while self.node.request_write():
                self.node.tick()

            neighbors = self.node.neighbors()
            if neighbors != known_neighbors:
                known_neighbors = neighbors
                print(f"Neighbors: {neighbors}")

            time.sleep(LOOP_SLEEP_S)


def main():
    parser = argparse.ArgumentParser(description="Yggdrasil hub for the Jetson Nano")
    parser.add_argument("--address", type=int, default=100, help="Yggdrasil/LoRa address of the hub")
    parser.add_argument("--ws", default=None, help="Websocket endpoint (e.g. ws://host:8765/readings) to stream raw reading payloads to; CSV logging is used if omitted")
    parser.add_argument("--csv", default="log.csv", help="CSV file to append readings to when --ws is not given")
    parser.add_argument("--port", default="/dev/ttyTHS1", help="RYLR896 serial port")
    parser.add_argument("--sf", type=int, default=7, help="LoRa spreading factor (7-12), must match every node")
    parser.add_argument("--bw", type=int, default=125000, choices=sorted(BANDWIDTH_CODES), help="LoRa bandwidth in Hz")
    parser.add_argument("--cr", type=int, default=1, choices=[1, 2, 3, 4], help="LoRa coding rate (1 = 4/5)")
    parser.add_argument("--preamble", type=int, default=4, choices=[4, 5, 6, 7], help="LoRa programmed preamble")
    parser.add_argument("--power", type=int, default=15, choices=range(16), help="RF output power in dBm")
    parser.add_argument("--trace", action="store_true", help="Print every frame sent and received")
    parser.add_argument("--max-children", type=int, default=MAX_CHILDREN, help="Maximum direct children before new nodes are refused and must hop through another node (0 = unlimited)")
    args = parser.parse_args()

    print("Jetson Nano Hub!")

    stream = None
    log = None
    if args.ws is not None:
        stream = WebSocketStream(args.ws)
        print(f"Streaming readings to {args.ws}")
    else:
        log = CsvLog(args.csv)
        print(f"Logging to {os.path.abspath(args.csv)}")

    radio = RYLR896(port=args.port)
    try:
        radio.send_command("AT")
        radio.send_command("AT+RESET", delay=1.0)
        radio.send_command(f"AT+ADDRESS={args.address}")
        radio.send_command(f"AT+NETWORKID={NETWORK_ID}")
        radio.send_command(f"AT+PARAMETER={args.sf},{BANDWIDTH_CODES[args.bw]},{args.cr},{args.preamble}")
        radio.send_command(f"AT+CRFOP={args.power}")
        radio.send_command("AT+ADDRESS?")
        radio.send_command("AT+NETWORKID?")
        radio.send_command("AT+PARAMETER?")

        hub = Hub(radio, log, stream, args.address, args.sf, args.bw, args.cr, args.preamble, args.power, trace=args.trace, max_children=args.max_children)
        radio.on_receive = hub.on_radio
        hub.run()

    except KeyboardInterrupt:
        print("\nShutting down.")
    finally:
        radio.close()
        if log is not None:
            log.close()
        if stream is not None:
            stream.close()


if __name__ == "__main__":
    main()
