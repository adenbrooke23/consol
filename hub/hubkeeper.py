#!/usr/bin/env python3
"""hubkeeper: the always-on supervisor for the CONSOL hub.

A hub that is down cannot be started over the network, so this keeper does
it. launchd keeps the keeper alive (KeepAlive + RunAtLoad, see
launchd/local.consol.hubkeeper.plist), and its only job is to start, stop,
and report on the hub process on port 8000.

Deliberately stdlib-only (no FastAPI, no uvicorn) so a broken hub venv can
never take the keeper down with it. The keeper does not own the hub process:
"running" means port 8000 answers, however the hub was started; start spawns
a detached uvicorn; stop asks the hub itself over HTTP (/admin/stop). The
keeper never holds a child handle it could lose track of.

Endpoints (port 8001, LAN):
    GET  /health  -> {ok, hub_running}
    GET  /status  -> {ok, hub_running}
    POST /start   -> starts the hub if down; 200 with final state
    POST /stop    -> stops the hub if up;   200 with final state
"""

import json
import os
import signal
import socket
import sqlite3
import subprocess
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

KEEPER_PORT = 8001
HUB_PORT = 8000
HUB_DIR = os.path.dirname(os.path.abspath(__file__))
UVICORN = os.path.join(HUB_DIR, ".venv", "bin", "uvicorn")
HUB_LOG = os.path.join(HUB_DIR, "hub.log")
# Start the hub when the keeper itself boots (login / reboot) unless disabled.
AUTOSTART = os.environ.get("HUBKEEPER_AUTOSTART", "1") != "0"

# Bonjour service type the app browses for. The keeper advertises it (it is
# always running), so the app can find this Mac and start the hub even when
# the hub is down.
BONJOUR_TYPE = "_consol-hub._tcp"


def advertise() -> None:
    """Register the hub service via mDNS, launchd-safe.

    launchd processes can't multicast themselves, but `dns-sd -R` only asks
    mDNSResponder (the system daemon) to do it, so registration works here.
    Spawned without a new session: launchd kills the keeper's process group
    on exit, so the advert dies with the keeper and a relaunch starts clean.
    Best-effort: a Mac without dns-sd still runs the hub fine.
    """
    try:
        subprocess.Popen(
            ["/usr/bin/dns-sd", "-R", "CONSOL Hub", BONJOUR_TYPE, ".",
             str(HUB_PORT), f"keeper={KEEPER_PORT}"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    except OSError:
        pass


def hub_running() -> bool:
    """The hub is running if its port answers. No pid bookkeeping to go stale."""
    try:
        with socket.create_connection(("127.0.0.1", HUB_PORT), timeout=1.0):
            return True
    except OSError:
        return False


# One lifecycle command at a time: a /start racing a /stop must not read the
# port mid-death and answer confidently wrong.
_lifecycle_lock = threading.Lock()

DB_PATH = os.path.join(HUB_DIR, "data.db")


def token_ok(authorization: str | None) -> bool:
    """Validate a Bearer token against the hub's own users table.

    The keeper reads the same SQLite database the hub writes, so there are no
    shared secrets to rotate and a dead hub can't lock the household out of
    /start. With no users yet (fresh install) it is open, matching the hub's
    bootstrap behavior.
    """
    try:
        conn = sqlite3.connect(DB_PATH)
        try:
            if conn.execute("SELECT COUNT(*) FROM users").fetchone()[0] == 0:
                return True
            if not authorization or not authorization.lower().startswith("bearer "):
                return False
            token = authorization[len("bearer "):].strip()
            row = conn.execute(
                "SELECT 1 FROM users WHERE api_token = ?", (token,)).fetchone()
            return row is not None
        finally:
            conn.close()
    except sqlite3.Error:
        return False   # unreadable db: fail closed


def start_hub() -> bool:
    if hub_running():
        return True
    try:   # a runaway log must not block starting
        if os.path.getsize(HUB_LOG) > 10_000_000:
            os.remove(HUB_LOG)
    except OSError:
        pass
    with open(HUB_LOG, "ab") as log:
        subprocess.Popen(
            [UVICORN, "main:app", "--host", "0.0.0.0", "--port", str(HUB_PORT)],
            cwd=HUB_DIR, stdout=log, stderr=log, start_new_session=True,
        )
    # Short grace only: the app's request timeout is 6s, so answer before
    # that. The app's own health poll covers a slow boot.
    for _ in range(16):
        time.sleep(0.25)
        if hub_running():
            return True
    return False


def stop_hub(authorization: str | None = None) -> bool:
    if not hub_running():
        return True
    try:
        req = urllib.request.Request(
            f"http://127.0.0.1:{HUB_PORT}/admin/stop", method="POST")
        if authorization:   # the hub's /admin/stop wants the caller's token
            req.add_header("Authorization", authorization)
        urllib.request.urlopen(req, timeout=5)
    except OSError:
        pass   # the hub may die before finishing the response; the poll decides
    for _ in range(20):
        time.sleep(0.25)
        if not hub_running():
            return True
    return False


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path in ("/health", "/status"):
            self._send(200, {"ok": True, "hub_running": hub_running()})
        else:
            self._send(404, {"detail": "not found"})

    def do_POST(self):
        try:
            if self.path in ("/start", "/stop") and not token_ok(
                    self.headers.get("Authorization")):
                self._send(401, {"detail": "missing or invalid token"})
                return
            if self.path == "/start":
                with _lifecycle_lock:
                    ok = start_hub()
                self._send(200 if ok else 502, {"ok": ok, "hub_running": hub_running()})
            elif self.path == "/stop":
                with _lifecycle_lock:
                    ok = stop_hub(self.headers.get("Authorization"))
                self._send(200 if ok else 502, {"ok": ok, "hub_running": hub_running()})
            else:
                self._send(404, {"detail": "not found"})
        except Exception as exc:   # missing venv, unwritable log: answer, don't drop
            self._send(500, {"ok": False, "detail": str(exc)})

    def log_message(self, fmt, *args):
        pass   # launchd captures stderr; request noise helps no one


if __name__ == "__main__":
    # Auto-reap spawned hubs: the keeper never wait()s, so without this a
    # stopped hub would linger as one zombie until the next start.
    signal.signal(signal.SIGCHLD, signal.SIG_IGN)
    advertise()
    if AUTOSTART:
        with _lifecycle_lock:
            start_hub()
    ThreadingHTTPServer(("0.0.0.0", KEEPER_PORT), Handler).serve_forever()
