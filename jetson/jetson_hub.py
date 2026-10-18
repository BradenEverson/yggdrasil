import csv
import os
import struct
import time
from datetime import datetime

from rylr896 import RYLR896

PAYLOAD_FORMAT = ">HhHIH"
PAYLOAD_SIZE = struct.calcsize(PAYLOAD_FORMAT)

CSV_PATH = "log.csv"
CSV_FIELDS = [
    "timestamp",
    "node_address",
    "pressure_hpa",
    "temperature_f",
    "humidity_pct",
    "gas_ohm",
    "power_mw",
]

csv_file = None
csv_writer = None

def open_csv(path):
    needs_header = not os.path.exists(path) or os.path.getsize(path) == 0
    f = open(path, "a", newline="")
    writer = csv.DictWriter(f, fieldnames=CSV_FIELDS)
    if needs_header:
        writer.writeheader()
        f.flush()
    return f, writer


def parse_payload(data: bytes):
    if len(data) != PAYLOAD_SIZE:
        raise ValueError(f"expected {PAYLOAD_SIZE} bytes, got {len(data)}")

    pressure_raw, temp_raw, hum_raw, gas_raw, power_mw = struct.unpack(PAYLOAD_FORMAT, data)

    return {
        "pressure_hpa": pressure_raw / 10.0,
        "temperature_f": temp_raw / 100.0,
        "humidity_pct": hum_raw / 100.0,
        "gas_ohm": gas_raw if gas_raw != 0 else None,
        "power": power_mw,
    }


def log_to_csv(address, r):
    csv_writer.writerow({
        "timestamp": datetime.now().isoformat(timespec="seconds"),
        "node_address": address,
        "pressure_hpa": r["pressure_hpa"],
        "temperature_f": r["temperature_f"],
        "humidity_pct": r["humidity_pct"],
        "gas_ohm": "" if r["gas_ohm"] is None else r["gas_ohm"],
        "power_mw": r["power"],
    })
    csv_file.flush()
    os.fsync(csv_file.fileno())


def handle_message(message):
    try:
        r = parse_payload(message["data"])
    except (ValueError, struct.error) as e:
        print(f"Bad payload from {message['address']}: {message['data']!r} ({e})")
        return

    gas = f"{r['gas_ohm']} ohm" if r["gas_ohm"] is not None else "n/a"
    print(
        f"From Node {message['address']}: "
        f"Pressure={r['pressure_hpa']:.1f} hPa  "
        f"Temp={r['temperature_f']:.2f} F  "
        f"Humidity={r['humidity_pct']:.2f}%  "
        f"Gas Resistance={gas}  "
        f"Power={r['power']} mW"
    )

    log_to_csv(message["address"], r)


def main():
    global csv_file, csv_writer

    print("Jetson Nano Runner!")

    csv_file, csv_writer = open_csv(CSV_PATH)
    print(f"Logging to {os.path.abspath(CSV_PATH)}")

    radio = RYLR896()
    radio.on_receive = handle_message

    try:
        radio.send_command("AT")
        radio.send_command("AT+RESET", delay=1.0)
        radio.send_command("AT+ADDRESS=2")
        radio.send_command("AT+NETWORKID=5")
        radio.send_command("AT+ADDRESS?")
        radio.send_command("AT+NETWORKID?")

        print("Listening for incoming messages...")
        while True:
            radio.poll()
            time.sleep(0.05)

    except KeyboardInterrupt:
        print("\nShutting down.")
    finally:
        radio.close()
        csv_file.close()


if __name__ == "__main__":
    main()
