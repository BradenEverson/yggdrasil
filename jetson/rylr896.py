import serial
import re
import time

class RYLR896:
    RCV_HEADER = re.compile(rb"\+RCV=(\d+),(\d+),")
    RCV_FOOTER = re.compile(rb"^,(-?\d+),(-?\d+)\r\n")

    def __init__(self, port="/dev/ttyTHS1", baud=115200):
        self.ser = serial.Serial(port, baud, timeout=0.5)
        self.on_receive = None
        self._buffer = bytearray()

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
            self._buffer += self.ser.read(self.ser.in_waiting)

        while self._try_parse_buffer():
            pass


    def _try_parse_buffer(self):
        if not self._buffer:
            return False

        header_match = self.RCV_HEADER.match(self._buffer)
        if header_match:
            length = int(header_match.group(2))
            payload_start = header_match.end()
            payload_end = payload_start + length

            if len(self._buffer) < payload_end:
                return False

            raw_data = bytes(self._buffer[payload_start:payload_end])

            footer_match = self.RCV_FOOTER.match(self._buffer, payload_end)
            if not footer_match:
                if b"\r\n" not in self._buffer[payload_end:]:
                    return False
                del self._buffer[:payload_end]
                print(f"Malformed +RCV footer after header: {header_match.group(0)!r}")
                return True

            address = int(header_match.group(1))
            rssi = int(footer_match.group(1))
            snr = int(footer_match.group(2))

            del self._buffer[:footer_match.end()]
            self._dispatch_message(address, length, raw_data, rssi, snr)
            return True

        newline_idx = self._buffer.find(b"\r\n")
        if newline_idx == -1:
            return False

        line = bytes(self._buffer[:newline_idx])
        del self._buffer[:newline_idx + 2]

        text = line.decode(errors="replace").strip()
        if text:
            print(f"Module: {text}")
        return True

    def _dispatch_message(self, address, length, raw_data, rssi, snr):
        message = {
            "address": address,
            "length": length,
            "data": raw_data,
            "rssi": rssi,
            "snr": snr,
        }
        print(f"Received from {message['address']}: {message['data']!r} "
              f"(RSSI {message['rssi']}, SNR {message['snr']})")
        if self.on_receive:
            try:
                self.on_receive(message)
            except Exception as e:
                print(f"on_receive callback error: {e}")

    def send_message(self, address, data):
        if isinstance(data, str):
            data_bytes = data.encode()
        else:
            data_bytes = data
        cmd = f'AT+SEND={address},{len(data_bytes)},'.encode() + data_bytes
        self.ser.write(cmd + b"\r\n")
        print(f"Sending: {cmd!r}")

    def close(self):
        self.ser.close()

