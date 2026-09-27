import serial
import time
import re


class RYLR896:
    RCV_PATTERN = re.compile(r"\+RCV=(\d+),(\d+),(.*?),(-?\d+),(-?\d+)")

    def __init__(self, port="/dev/ttyTHS1", baud=115200):
        self.ser = serial.Serial(port, baud, timeout=0.5)
        self.on_receive = None
        self._buffer = ""

    def send_command(self, cmd, delay=0.2):
        full_cmd = f"{cmd}\r\n"
        self.ser.write(full_cmd.encode())
        print(f"Sending: {cmd}")

        time.sleep(delay)

        response = self.ser.read(self.ser.in_waiting or 1).decode(errors="replace")
        if response:
            print(f"Response: {response.strip()}")
        else:
            print("no response :(")
        print()
        return response

    def poll(self):
        if self.ser.in_waiting:
            chunk = self.ser.read(self.ser.in_waiting).decode(errors="replace")
            self._buffer += chunk

            while "\r\n" in self._buffer:
                line, self._buffer = self._buffer.split("\r\n", 1)
                line = line.strip()
                if line:
                    self._handle_line(line)

    def _handle_line(self, line):
        match = self.RCV_PATTERN.match(line)
        if match:
            address, length, data, rssi, snr = match.groups()
            message = {
                "address": int(address),
                "length": int(length),
                "data": data,
                "rssi": int(rssi),
                "snr": int(snr),
            }
            print(f"Received from {message['address']}: {message['data']!r} "
                  f"(RSSI {message['rssi']}, SNR {message['snr']})")
            if self.on_receive:
                try:
                    self.on_receive(message)
                except Exception as e:
                    print(f"on_receive callback error: {e}")
        else:
            print(f"Module: {line}")

    def send_message(self, address, data):
        return self.send_command(f'AT+SEND={address},{len(data)},{data}')

    def close(self):
        self.ser.close()


def handle_message(message):
    pass


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
