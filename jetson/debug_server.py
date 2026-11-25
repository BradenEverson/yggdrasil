import argparse
import threading
from collections import deque
from datetime import datetime

from websockets.exceptions import ConnectionClosed
from websockets.sync.server import serve

from hub_stream import decode_frame

HUB_PATH = "/hub"
ROSIE_PATH = "/rosie"
MAX_BACKLOG_FRAMES = 1000


class Relay(object):
    def __init__(self):
        self.lock = threading.Lock()
        self.hub = None
        self.rosie = None
        self.backlog = deque(maxlen=MAX_BACKLOG_FRAMES)

    def claim(self, role, ws):
        with self.lock:
            previous = getattr(self, role)
            setattr(self, role, ws)
        if previous is not None:
            print(f"New {role} connection replaces the old one")
            threading.Thread(
                target=previous.close,
                args=(1000, f"replaced by a newer {role} connection"),
                daemon=True,
            ).start()

    def release(self, role, ws):
        with self.lock:
            if getattr(self, role) is ws:
                setattr(self, role, None)

    def attach_rosie(self, ws):
        self.claim("rosie", ws)
        with self.lock:
            while self.backlog and self.rosie is ws:
                try:
                    ws.send(self.backlog[0])
                except ConnectionClosed:
                    return
                self.backlog.popleft()
            if self.rosie is ws:
                print("Rosie caught up")

    def forward(self, frame):
        with self.lock:
            if self.rosie is not None:
                try:
                    self.rosie.send(frame)
                    return
                except ConnectionClosed:
                    self.rosie = None
            if len(self.backlog) == self.backlog.maxlen:
                print("Backlog full, dropping oldest frame")
            self.backlog.append(frame)
            print(f"Rosie not connected, {len(self.backlog)} frames held")


relay = Relay()


def handle_hub(ws):
    relay.claim("hub", ws)
    print("Hub connected")
    try:
        for msg in ws:
            if isinstance(msg, str):
                print("Ignoring text message from hub")
                continue
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
            relay.forward(msg)
    finally:
        relay.release("hub", ws)
        print("Hub disconnected")


def handle_rosie(ws):
    print("Rosie connected")
    relay.attach_rosie(ws)
    try:
        for _ in ws:
            pass
    finally:
        relay.release("rosie", ws)
        print("Rosie disconnected")


ROUTES = {
    HUB_PATH: handle_hub,
    ROSIE_PATH: handle_rosie,
}


def handle(ws):
    path = ws.request.path.split("?", 1)[0].rstrip("/")
    route = ROUTES.get(path)
    if route is None:
        print(f"Rejecting connection to unknown path {ws.request.path!r}")
        ws.close(1008, "connect to /hub or /rosie")
        return
    route(ws)


def main():
    parser = argparse.ArgumentParser(description="Relays hub readings to the rosie server")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=6767)
    args = parser.parse_args()

    with serve(handle, args.host, args.port) as server:
        print(f"Hub: ws://{args.host}:{args.port}{HUB_PATH}  Rosie: ws://{args.host}:{args.port}{ROSIE_PATH}")
        server.serve_forever()


if __name__ == "__main__":
    main()
