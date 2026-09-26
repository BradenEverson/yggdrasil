import serial
import time


class RYLR896:
    def __init__(self, port="/dev/ttyTHS1", baud=115200):
        self.ser = serial.Serial(port, baud, timeout=0.5)
        self.on_receive = None

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

    def close(self):
        self.ser.close()


def main():
    print("Jetson Nano Runner!")

    radio = RYLR896()

    try:
        radio.send_command("AT")

        radio.send_command("AT+RESET", delay=1.0)

        radio.send_command("AT+ADDRESS=1")

        radio.send_command("AT+NETWORKID=5")

        radio.send_command("AT+ADDRESS?")
        radio.send_command("AT+NETWORKID?")

    finally:
        radio.close()


if __name__ == "__main__":
    main()
