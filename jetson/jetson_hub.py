import struct
import time
from rylr896 import RYLR896

PAYLOAD_FORMAT = ">HhHI"
PAYLOAD_SIZE = struct.calcsize(PAYLOAD_FORMAT)

def parse_payload(data: bytes):
    if len(data) != PAYLOAD_SIZE:
        raise ValueError(f"expected {PAYLOAD_SIZE} bytes, got {len(data)}")

    pressure_raw, temp_raw, hum_raw, gas_raw = struct.unpack(PAYLOAD_FORMAT, data)

    return {
        "pressure_hpa": pressure_raw / 10.0,
        "temperature_f": temp_raw / 100.0,
        "humidity_pct": hum_raw / 100.0,
        "gas_ohm": gas_raw if gas_raw != 0 else None,
    }

def handle_message(message):
    try:
        r = parse_payload(message["data"])
    except (ValueError, struct.error) as e:
        print(f"Bad payload from {message['address']}: {message['data']!r} ({e})")
        return

    gas = f"{r['gas_ohm']} ohm" if r["gas_ohm"] is not None else "n/a"
    print(
        f"[{message['address']}] "
        f"P={r['pressure_hpa']:.1f} hPa  "
        f"T={r['temperature_f']:.2f} F  "
        f"H={r['humidity_pct']:.2f} %  "
        f"Gas={gas}"
    )


def main():
    print("Jetson Nano Runner!")

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


if __name__ == "__main__":
    main()
