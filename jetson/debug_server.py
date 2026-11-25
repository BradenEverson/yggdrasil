from datetime import datetime

from websockets.sync.server import serve

from hub_stream import decode_frame


def handle(ws):
    print("Hub connected")
    for msg in ws:
        try:
            records = decode_frame(msg)
        except ValueError as e:
            print(f"Bad frame ({len(msg)} bytes): {e}")
            continue
        print(f"Frame: {len(records)} readings, {len(msg)} bytes")
        for record in records:
            when = datetime.fromtimestamp(record["time"]).isoformat(timespec="seconds")
            readings = "  ".join(f"{name}={value}" for name, value in record["readings"].items())
            print(f"  {when} node {record['node']} (via {record['via']}, rssi {record['rssi']}, snr {record['snr']}): {readings}")
    print("Hub disconnected")


with serve(handle, "0.0.0.0", 6767) as server:
    print("Listening on ws://0.0.0.0:6767")
    server.serve_forever()
