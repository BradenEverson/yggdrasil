from websockets.sync.server import serve

from yggdrasil import parse_sensor_readings


def handle(ws):
    print("Hub connected")
    for msg in ws:
        origin = int.from_bytes(msg[:2], "big")
        print(f"node {origin}: {parse_sensor_readings(msg[2:])}")
    print("Hub disconnected")


with serve(handle, "0.0.0.0", 6767) as server:
    print("Listening on ws://0.0.0.0:6767")
    server.serve_forever()
