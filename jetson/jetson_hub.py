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


class Hub(object):
    def __init__(self, radio, log, address, sf, bandwidth_hz, coding_rate, preamble):
        self.radio = radio
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

    def transmit(self, frame):
        return self.radio.send_data(RADIO_BROADCAST_ADDR, frame)

    def on_radio(self, message):
        self.last_rssi = message["rssi"]
        self.last_snr = message["snr"]
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
        known_neighbors = []

        print("Hub running...")
        while True:
            self.node.tick()
            self.radio.poll()

            now = time.monotonic()
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

        hub = Hub(radio, log, args.address, args.sf, args.bw, args.cr, args.preamble)
        radio.on_receive = hub.on_radio
        hub.run()

    except KeyboardInterrupt:
        print("\nShutting down.")
    finally:
        radio.close()
        log.close()


if __name__ == "__main__":
    main()
