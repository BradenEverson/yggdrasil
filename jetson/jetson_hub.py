import serial

class RYLR896:
    def __init__(self, port="/dev/ttyTHS1", baud=115200):
        self.ser = serial.Serial(port, baud, timeout=0.1)
        self.on_receive = None


def main():
    print("Jetson Nano Runner!")


if __name__ == "__main__":
    main()
