#!/usr/bin/env python3
"""Holds OnTime's push schedule and fires each push at its time. Runs on the
Pi (warden) as ontime-push.service.

The app uploads a list of events. Each one is an absolute clock time and the
exact APNs payload to deliver then. This process does no scheduling math and
knows nothing about routines: it holds the list and watches the clock. An
upload replaces the whole list.

    POST /schedule   {"pushToStartToken": hex, "events": [{id, fireAt, expiresAt, aps, token?}]}
    GET  /status     what is pending, and the last sends with APNs's answers

Listens on the Tailscale address only, so nothing off the tailnet can reach
it. State lives in ~/.ontime-push, not /tmp, which is cleared on boot.
"""

import argparse
import json
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import jwt

TEAM_ID = "34ZCK63GEC"
KEY_ID = "VSZ8PR7KG4"
BUNDLE_ID = "com.mammer55.ontime"
STATE_DIR = Path.home() / ".ontime-push"
KEY_PATH = STATE_DIR / f"AuthKey_{KEY_ID}.p8"
SCHEDULE_PATH = STATE_DIR / "schedule.json"
SENT_PATH = STATE_DIR / "sent.json"

# A build installed from Xcode registers with the sandbox.
APNS_HOST = "https://api.sandbox.push.apple.com"

# APNs rejects a provider that mints a new token more than once every twenty
# minutes (TooManyProviderTokenUpdates) and one older than an hour, so one
# token is kept and reused inside that window.
TOKEN_LIFETIME = 40 * 60

lock = threading.Lock()
_token = {"value": None, "minted": 0.0}


def log(message: str) -> None:
    print(time.strftime("%Y-%m-%d %H:%M:%S"), message, flush=True)


def bearer_token() -> str:
    now = time.time()
    if _token["value"] is None or now - _token["minted"] > TOKEN_LIFETIME:
        _token["value"] = jwt.encode(
            {"iss": TEAM_ID, "iat": int(now)},
            KEY_PATH.read_text(),
            algorithm="ES256",
            headers={"kid": KEY_ID},
        )
        _token["minted"] = now
    return _token["value"]


def read_json(path: Path, default):
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return default


def write_json(path: Path, value) -> None:
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=1))
    temporary.replace(path)


def deliver(device_token: str, aps: dict) -> str:
    """Sends one Live Activity push. Returns APNs's answer as text."""
    payload = {"aps": dict(aps, timestamp=int(time.time()))}
    result = subprocess.run(
        [
            "curl", "--silent", "--show-error", "--http2", "--max-time", "20",
            "--write-out", " HTTP %{http_code}",
            "--header", f"authorization: bearer {bearer_token()}",
            "--header", f"apns-topic: {BUNDLE_ID}.push-type.liveactivity",
            "--header", "apns-push-type: liveactivity",
            "--header", "apns-priority: 10",
            "--data", json.dumps(payload),
            f"{APNS_HOST}/3/device/{device_token}",
        ],
        capture_output=True,
        text=True,
    )
    return (result.stdout + result.stderr).strip()


def describe(event: dict) -> str:
    """A label for an event with no alert: which step an update moves to."""
    state = event["aps"].get("content-state", {})
    return f"{event['aps'].get('event', '?')}: {state.get('planName', '')} / {state.get('blockName', '')}"


def fire_due() -> None:
    now = time.time()
    with lock:
        schedule = read_json(SCHEDULE_PATH, {"events": []})
        sent = read_json(SENT_PATH, [])
        sent_ids = {entry["id"] for entry in sent}
        due = [
            event for event in schedule.get("events", [])
            if event["fireAt"] <= now < event["expiresAt"] and event["id"] not in sent_ids
        ]
        token = schedule.get("pushToStartToken")
    # In time order: a Pi that was down through two step changes sends both
    # when it comes back, and the phone has to end on the later one.
    for event in sorted(due, key=lambda e: e["fireAt"]):
        # A start goes to the push to start token the upload carries. An
        # update or an end names the token of the activity it changes.
        answer = deliver(event.get("token") or token, event["aps"])
        title = event["aps"].get("alert", {}).get("title", "") or describe(event)
        log(f"sent {event['id']} ({title}): {answer}")
        with lock:
            sent = read_json(SENT_PATH, [])
            # Recorded whatever APNs said. A rejected push retried every
            # second until it expires helps nobody, and the answer is in
            # /status for whoever comes looking.
            sent.append({"id": event["id"], "title": title, "at": now, "answer": answer})
            write_json(SENT_PATH, sent[-300:])


def clock_loop() -> None:
    while True:
        try:
            fire_due()
        except Exception as error:  # the loop must outlive any one bad event
            log(f"clock loop error: {error!r}")
        time.sleep(1)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def answer(self, status: int, body: dict) -> None:
        data = json.dumps(body, indent=1).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        if self.path != "/schedule":
            return self.answer(404, {"error": "not found"})
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
            events = body["events"]
            token = body["pushToStartToken"]
            for event in events:
                _ = event["id"], float(event["fireAt"]), float(event["expiresAt"]), event["aps"]
        except (ValueError, KeyError, TypeError) as error:
            return self.answer(400, {"error": repr(error)})
        with lock:
            write_json(SCHEDULE_PATH, {"pushToStartToken": token, "events": events,
                                       "receivedAt": time.time()})
        log(f"schedule replaced: {len(events)} event(s)")
        self.answer(200, {"events": len(events)})

    def do_GET(self):
        if self.path != "/status":
            return self.answer(404, {"error": "not found"})
        with lock:
            schedule = read_json(SCHEDULE_PATH, {"events": []})
            sent = read_json(SENT_PATH, [])
        stamp = lambda t: time.strftime("%a %H:%M:%S", time.localtime(t))
        sent_ids = {entry["id"] for entry in sent}
        self.answer(200, {
            "now": stamp(time.time()),
            "scheduleReceived": stamp(schedule["receivedAt"]) if "receivedAt" in schedule else None,
            "hasToken": bool(schedule.get("pushToStartToken")),
            "pending": [
                {"title": e["aps"].get("alert", {}).get("title", "") or describe(e), "fireAt": stamp(e["fireAt"]), "id": e["id"]}
                for e in sorted(schedule.get("events", []), key=lambda e: e["fireAt"])
                if e["id"] not in sent_ids
            ],
            "sent": [dict(entry, at=stamp(entry["at"])) for entry in sent[-10:]],
        })


def tailscale_address() -> str:
    """The 100.64.0.0/10 address of this machine, found without shelling out
    to the tailscale binary."""
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(("100.100.100.100", 53))
        return probe.getsockname()[0]
    finally:
        probe.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", type=int, default=8790)
    parser.add_argument("--host", default=None, help="defaults to the Tailscale address")
    args = parser.parse_args()

    STATE_DIR.mkdir(mode=0o700, exist_ok=True)
    host = args.host or tailscale_address()
    threading.Thread(target=clock_loop, daemon=True).start()
    server = ThreadingHTTPServer((host, args.port), Handler)
    log(f"listening on {host}:{args.port}")
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
