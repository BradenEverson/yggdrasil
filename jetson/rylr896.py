import serial
import re
import time

class RYLR896:
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
        buf = self._buffer
        if not buf:
            return False

        if not buf.startswith(b"+RCV="):
            newline_idx = buf.find(b"\r\n")
            if newline_idx == -1:
                return False
            line = bytes(buf[:newline_idx])
            del buf[:newline_idx + 2]
            text = line.decode(errors="replace").strip()
            if text:
                print(f"Module: {text}")
            return True

        prefix_len = len(b"+RCV=")

        addr_comma = buf.find(b",", prefix_len)
        if addr_comma == -1:
            return False

        len_comma = buf.find(b",", addr_comma + 1)
        if len_comma == -1:
            return False

        try:
            address = int(buf[prefix_len:addr_comma])
            length = int(buf[addr_comma + 1:len_comma])
        except ValueError:
            del buf[:prefix_len]
            print("Malformed +RCV header, resyncing")
            return True

        payload_start = len_comma + 1
        payload_end = payload_start + length
        if len(buf) < payload_end:
            return False

        raw_data = bytes(buf[payload_start:payload_end])

        if buf[payload_end:payload_end + 1] != b",":
            del buf[:payload_end]
            print("Malformed +RCV footer (missing comma after payload)")
            return True

        rssi_start = payload_end + 1
        rssi_comma = buf.find(b",", rssi_start)
        if rssi_comma == -1:
            return False

        snr_start = rssi_comma + 1
        line_end = buf.find(b"\r\n", snr_start)
        if line_end == -1:
            return False

        try:
            rssi = int(buf[rssi_start:rssi_comma])
            snr = int(buf[snr_start:line_end])
        except ValueError:
            del buf[:line_end + 2]
            print("Malformed rssi/snr in +RCV footer, resyncing")
            return True

        consumed_end = line_end + 2
        del buf[:consumed_end]

        self._dispatch_message(address, length, raw_data, rssi, snr)
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

