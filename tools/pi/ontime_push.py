#!/usr/bin/env python3
"""Sends a Live Activity push to OnTime through APNs. Runs on the Pi (warden).

The app cannot put a countdown in the Dynamic Island while it is closed, and
it cannot move one to the next step while it is suspended. APNs can do both.
This is the sender.

First slice: one command, `start`, that raises a test countdown on the phone
with the app closed.

    ontime_push.py start --token <hex> [--minutes 10]

Needs pyjwt and cryptography (both already on the Pi) and a curl built with
HTTP/2, which APNs requires. The signing key is read from KEY_PATH and is
never printed.
"""

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

import jwt

TEAM_ID = "34ZCK63GEC"
KEY_ID = "VSZ8PR7KG4"
BUNDLE_ID = "com.mammer55.ontime"
KEY_PATH = Path.home() / ".ontime-push" / f"AuthKey_{KEY_ID}.p8"

# A build installed from Xcode registers with the sandbox. A TestFlight or
# App Store build would need api.push.apple.com instead.
APNS_HOST = "https://api.sandbox.push.apple.com"

# ActivityKit decodes `content-state` with a plain JSONDecoder, whose default
# Date strategy is seconds since 1 Jan 2001, not the Unix epoch. `stale-date`
# and `timestamp` belong to APNs rather than to the app's Codable type, and
# those are Unix seconds.
REFERENCE_DATE_OFFSET = 978307200


def bearer_token() -> str:
    key = KEY_PATH.read_text()
    return jwt.encode(
        {"iss": TEAM_ID, "iat": int(time.time())},
        key,
        algorithm="ES256",
        headers={"kid": KEY_ID},
    )


def send(device_token: str, payload: dict) -> int:
    result = subprocess.run(
        [
            "curl", "--silent", "--show-error", "--http2",
            "--write-out", "\nHTTP %{http_code}\n",
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
    print((result.stdout + result.stderr).strip())
    return 0 if "HTTP 200" in result.stdout else 1


def start(args: argparse.Namespace) -> int:
    now = int(time.time())
    target = now + args.minutes * 60
    # Every field of OnTimeActivityAttributes.ContentState that has no
    # Optional type must be here, or the phone drops the push silently.
    state = {
        "planName": "Push test",
        "blockName": "Started by the Pi",
        "blockIndex": 0,
        "totalBlocks": 3,
        "targetLeaveBy": target - REFERENCE_DATE_OFFSET,
        "segmentStart": now - REFERENCE_DATE_OFFSET,
        "isFlex": False,
        "isFinished": False,
        "symbol": "bolt.fill",
        "isWaiting": False,
        "targetLabel": "Finish by ",
        "isOverrun": False,
        "startsRunAtTarget": False,
        "endsRunAtTarget": False,
    }
    payload = {
        "aps": {
            "timestamp": now,
            "event": "start",
            "content-state": state,
            "stale-date": target,
            "attributes-type": "OnTimeActivityAttributes",
            # The "pushtest" prefix is what the app's launch sweeps spare.
            # See LiveActivityManager.pushTestPrefix.
            "attributes": {"planId": f"pushtest-{now}"},
            "alert": {"title": "On Time", "body": "Push test"},
        }
    }
    return send(args.token, payload)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)

    start_parser = commands.add_parser("start", help="raise a test countdown on the phone")
    start_parser.add_argument("--token", required=True, help="push to start token, hex")
    start_parser.add_argument("--minutes", type=int, default=10)
    start_parser.set_defaults(run=start)

    args = parser.parse_args()
    return args.run(args)


if __name__ == "__main__":
    sys.exit(main())
