import os
import sys
from datetime import datetime

import websocket

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "jetson"))
from hub_stream import decode_frame

url = sys.argv[1]
ws = websocket.create_connection(url)
print(f"Listening on {url}")

while True:
    for record in decode_frame(ws.recv()):
        when = datetime.fromtimestamp(record["time"]).isoformat(timespec="seconds")
        readings = "  ".join(f"{name}={value}" for name, value in record["readings"].items())
        print(f"{when} node {record['node']}: {readings}")
