import argparse
import csv
import os
import random
import time
from datetime import datetime

import yggdrasil
from rylr896 import RYLR896

NETWORK_ID = 5
RADIO_BROADCAST_ADDR = 0
ROOT_ANNOUNCE_PERIOD_S = 15 * 60.0
ROOT_ANNOUNCE_JITTER_S = 30.0
LOOP_SLEEP_S = 0.005
RADIO_CHECK_PERIOD_S = 60.0
ROOT_BEACON_MS = 20_000

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


def describe_frame(frame):
    if len(frame) < 18 or frame[0] != 0x72:
        return f"(not a frame, {len(frame)} bytes)"
    src = (frame[1] << 8) | frame[2]
    dst = (frame[3] << 8) | frame[4]
    flags = frame[10]
    length = frame[11]
    wake = (frame[12] << 16) | (frame[13] << 8) | frame[14]
    period = ((frame[15] << 8) | frame[16]) * 100
    hops = frame[17]
    names = [n for i, n in enumerate(["ack", "bcast", "nack", "sn", "nesn"]) if flags & (1 << (7 - i))]
    op = frame[18] if length else None
    return f"{src}>{dst} len={length} op={op} hops={hops} period={period} wake={wake} [{','.join(names)}]"


class Hub(object):
    def __init__(self, radio, log, address, sf, bandwidth_hz, coding_rate, preamble, tx_power, trace=False):
        self.trace = trace
        self.radio = radio
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
            self.on_readings(origin, from_addr, payload)
        elif op == yggdrasil.OP_HELLO and broadcast:
            print(f"Hello from {from_addr}")

    def on_readings(self, origin, from_addr, payload):
        readings = yggdrasil.parse_sensor_readings(payload)

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

        pretty = "  ".join(f"{n}={v:.2f}" if isinstance(v, float) else f"{n}={v}" for n, v in readings)
        print(f"From Node {origin} (via {from_addr}, rssi {self.last_rssi}): {pretty}")
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
    parser.add_argument("--csv", default="log.csv", help="CSV file to append readings to")
    parser.add_argument("--port", default="/dev/ttyTHS1", help="RYLR896 serial port")
    parser.add_argument("--sf", type=int, default=9, help="LoRa spreading factor (7-12), must match every node")
    parser.add_argument("--bw", type=int, default=125000, choices=sorted(BANDWIDTH_CODES), help="LoRa bandwidth in Hz")
    parser.add_argument("--cr", type=int, default=1, choices=[1, 2, 3, 4], help="LoRa coding rate (1 = 4/5)")
    parser.add_argument("--preamble", type=int, default=4, choices=[4, 5, 6, 7], help="LoRa programmed preamble")
    parser.add_argument("--power", type=int, default=15, choices=range(16), help="RF output power in dBm")
    parser.add_argument("--trace", action="store_true", help="Print every frame sent and received")
    args = parser.parse_args()

    print("Jetson Nano Hub!")

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

        hub = Hub(radio, log, args.address, args.sf, args.bw, args.cr, args.preamble, args.power, trace=args.trace)
        radio.on_receive = hub.on_radio
        hub.run()

    except KeyboardInterrupt:
        print("\nShutting down.")
    finally:
        radio.close()
        log.close()


if __name__ == "__main__":
    main()
