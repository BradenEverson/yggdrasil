import time
from rylr896 import RYLR896


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
