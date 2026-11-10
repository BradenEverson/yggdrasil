import argparse
import time

import serial


def drain(ser, seconds, label):
    end = time.monotonic() + seconds
    start = time.monotonic()
    got = bytearray()
    while time.monotonic() < end:
        chunk = ser.read(ser.in_waiting or 1)
        if chunk:
            got += chunk
            print(f"  [{label} +{(time.monotonic() - start) * 1000:7.1f} ms] {chunk!r}")
    if not got:
        print(f"  [{label}] no response in {seconds:.1f} s")
    return bytes(got)


def command(ser, text, wait=1.0):
    print(f"> {text}")
    ser.write(text.encode() + b"\r\n")
    return drain(ser, wait, text)


def main():
    parser = argparse.ArgumentParser(description="Probe how the RYLR896 sleeps and wakes")
    parser.add_argument("--port", default="/dev/ttyTHS1")
    parser.add_argument("--listen", type=float, default=15.0, help="Seconds to listen for +RCV after waking")
    args = parser.parse_args()

    ser = serial.Serial(args.port, 115200, timeout=0.05)
    drain(ser, 0.3, "flush")

    command(ser, "AT")
    command(ser, "AT+MODE?")
    command(ser, "AT+PARAMETER?")
    command(ser, "AT+MODE=1")

    print("sleeping 3 s")
    time.sleep(3)
    drain(ser, 0.1, "asleep")

    command(ser, "AT", wait=2.0)
    command(ser, "AT", wait=1.0)
    command(ser, "AT+MODE?", wait=1.0)

    print(f"listening {args.listen:.0f} s without AT+MODE=0 (does it receive?)")
    drain(ser, args.listen, "rx")

    command(ser, "AT+MODE=0")
    command(ser, "AT+MODE?")
    print(f"listening {args.listen:.0f} s after AT+MODE=0")
    drain(ser, args.listen, "rx")

    ser.close()


if __name__ == "__main__":
    main()
