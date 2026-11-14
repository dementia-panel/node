import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from urllib.error import HTTPError
from urllib.request import HTTPRedirectHandler, Request, build_opener

os.umask(0o077)
BASE = Path("/var/lib/dementia")
STATE = BASE / "state.json"
RESTART = BASE / "restart-revision"
NAME = BASE / "node-name"
restarted = int(RESTART.read_text()) if RESTART.exists() else 0
applied_peers = None
panel_url, node_id, token = (BASE / "agent.conf").read_text().splitlines()
url = f"{panel_url}/api/agent/nodes/{node_id}"


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


opener = build_opener(NoRedirect())


def request(path, payload=None):
    data = None if payload is None else json.dumps(payload).encode()
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    with opener.open(Request(url + path, data=data, headers=headers), timeout=4) as response:
        return json.load(response)


def apply(state):
    now = datetime.datetime.now(datetime.timezone.utc)
    global applied_peers
    peers = [
        (peer["public_key"], peer["address"])
        for peer in state["peers"]
        if datetime.datetime.fromisoformat(peer["expires_at"].replace("Z", "+00:00")) > now
    ]
    if peers == applied_peers:
        return
    config = (BASE / "awgp0.conf").read_text()
    config += "".join(
        f"\n[Peer]\nPublicKey = {key}\nAllowedIPs = {address}\n"
        for key, address in peers
    )
    target = BASE / "desired.conf"
    target.write_text(config)
    subprocess.run(["awg", "syncconf", "awgp0", str(target)], check=True, timeout=4)
    applied_peers = peers


def write_atomic(path, value):
    temp = path.with_name(path.name + ".tmp")
    temp.write_text(value)
    temp.replace(path)


def save(state):
    serialized = json.dumps(state)
    if not STATE.exists() or STATE.read_text() != serialized:
        write_atomic(STATE, serialized)


def handshakes():
    result = subprocess.run(
        ["awg", "show", "awgp0", "latest-handshakes"],
        check=True, capture_output=True, text=True, timeout=4,
    )
    reports = {}
    for line in result.stdout.splitlines():
        key, value = line.split()
        timestamp = int(value)
        if timestamp > 0:
            reports[key] = timestamp
    return reports


def transfer():
    result = subprocess.run(
        ["awg", "show", "awgp0", "transfer"],
        check=True, capture_output=True, text=True, timeout=4,
    )
    reports = {}
    for line in result.stdout.splitlines():
        key, received, sent = line.split()
        reports[key] = {"received": int(received), "sent": int(sent)}
    return reports


def sync():
    try:
        state = request("/state")
    except OSError as error:
        if isinstance(error, HTTPError) and error.code in (401, 403):
            state = {"revision": 0, "peers": []}
            save(state)
        elif STATE.exists():
            state = json.loads(STATE.read_text())
        else:
            state = {"revision": 0, "peers": []}
        apply(state)
    else:
        traffic = None
        try:
            traffic = transfer()
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            print(f"Traffic report failed: {type(error).__name__}", file=sys.stderr, flush=True)
        apply(state)
        save(state)
        if name := state.get("name"):
            value = name + "\n"
            if not NAME.exists() or NAME.read_text() != value:
                write_atomic(NAME, value)
        restart = state.get("restart_revision", 0)
        if restart > restarted:
            write_atomic(RESTART, str(restart))
            # The supervisor exits when this agent exits, so Docker restarts both processes.
            sys.exit(0)
        payload = {"revision": state["revision"]}
        if restarted:
            payload["restarted_revision"] = restarted
        try:
            payload["handshakes"] = handshakes()
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            print(f"Handshake report failed: {type(error).__name__}", file=sys.stderr, flush=True)
        if traffic is not None:
            payload["traffic"] = traffic
        request("/ack", payload)


while True:
    try:
        sync()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Node synchronization failed: {type(error).__name__}", file=sys.stderr, flush=True)
    time.sleep(5)
