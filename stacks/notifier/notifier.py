#!/usr/bin/env python3
"""
Shellpocket Notifier — companion container that watches home-server services
and sends APNs push notifications to registered Shellpocket installs.

Watches:
  * qBittorrent  — torrent finished downloading
  * Prometheus   — CPU / RAID-degraded thresholds
  * Service health — HTTP probes of configured endpoints (down/up transitions)

Endpoints:
  POST /register   {"token": "<hex APNs device token>", "topics": ["torrents","alerts","health"]}
  POST /unregister {"token": "..."}
  GET  /healthz

Configuration (environment):
  APNS_KEY_PATH    path to the .p8 APNs auth key            (required)
  APNS_KEY_ID      key ID of the .p8                        (required)
  APNS_TEAM_ID     Apple developer team ID                  (required)
  APNS_TOPIC       app bundle ID (com.homepilot.HomePilot)  (required)
  APNS_SANDBOX     "1" to use the sandbox APNs host         (default off)
  QBIT_URL         e.g. http://qbittorrent:8080             (optional)
  QBIT_USER / QBIT_PASS
  PROM_URL         e.g. http://prometheus:9090              (optional)
  CPU_THRESHOLD    percent, default 90
  PROBE_URLS       comma-separated name=url pairs, e.g.
                   "Dockge=http://dockge:5001,Plex=http://plex:32400/identity"
  POLL_SECONDS     default 60
  STATE_DIR        default /data (volume for tokens + seen-state)
"""

import json
import os
import time
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import httpx
import jwt  # PyJWT

STATE_DIR = Path(os.environ.get("STATE_DIR", "/data"))
STATE_DIR.mkdir(parents=True, exist_ok=True)
TOKENS_FILE = STATE_DIR / "tokens.json"
SEEN_FILE = STATE_DIR / "seen.json"

POLL_SECONDS = int(os.environ.get("POLL_SECONDS", "60"))
CPU_THRESHOLD = float(os.environ.get("CPU_THRESHOLD", "90"))

_lock = threading.Lock()


def load_json(path: Path, default):
    if path.exists():
        try:
            return json.loads(path.read_text())
        except json.JSONDecodeError:
            pass
    return default


def save_json(path: Path, value) -> None:
    path.write_text(json.dumps(value, indent=2))


# ---------------------------------------------------------------- APNs

class APNs:
    def __init__(self):
        self.key_path = os.environ["APNS_KEY_PATH"]
        self.key_id = os.environ["APNS_KEY_ID"]
        self.team_id = os.environ["APNS_TEAM_ID"]
        self.topic = os.environ["APNS_TOPIC"]
        host = ("api.sandbox.push.apple.com"
                if os.environ.get("APNS_SANDBOX") == "1"
                else "api.push.apple.com")
        self.base = f"https://{host}"
        self._jwt = None
        self._jwt_issued = 0.0
        self.client = httpx.Client(http2=True, timeout=10)

    def _token(self) -> str:
        # APNs JWTs are valid 20–60 min; refresh at 40.
        if self._jwt is None or time.time() - self._jwt_issued > 2400:
            key = Path(self.key_path).read_text()
            self._jwt = jwt.encode(
                {"iss": self.team_id, "iat": int(time.time())},
                key, algorithm="ES256", headers={"kid": self.key_id},
            )
            self._jwt_issued = time.time()
        return self._jwt

    def send(self, device_token: str, title: str, body: str, thread: str) -> bool:
        payload = {
            "aps": {
                "alert": {"title": title, "body": body},
                "sound": "default",
                "thread-id": thread,
            }
        }
        try:
            resp = self.client.post(
                f"{self.base}/3/device/{device_token}",
                json=payload,
                headers={
                    "authorization": f"bearer {self._token()}",
                    "apns-topic": self.topic,
                    "apns-push-type": "alert",
                    "apns-priority": "10",
                },
            )
            if resp.status_code == 410:  # token no longer valid
                unregister_token(device_token)
                return False
            if resp.status_code != 200:
                print(f"[apns] {resp.status_code} {resp.text} for {device_token[:8]}…", flush=True)
                return False
            return True
        except httpx.HTTPError as e:
            print(f"[apns] transport error: {e}", flush=True)
            return False


def broadcast(apns: APNs, topic: str, title: str, body: str) -> None:
    with _lock:
        tokens = load_json(TOKENS_FILE, {})
    sent = 0
    for token, info in tokens.items():
        if topic in info.get("topics", []):
            if apns.send(token, title, body, thread=topic):
                sent += 1
    print(f"[notify] {topic}: \"{title} — {body}\" → {sent} device(s)", flush=True)


def unregister_token(token: str) -> None:
    with _lock:
        tokens = load_json(TOKENS_FILE, {})
        if token in tokens:
            del tokens[token]
            save_json(TOKENS_FILE, tokens)
            print(f"[register] pruned dead token {token[:8]}…", flush=True)


# ---------------------------------------------------------------- Watchers

class QbitWatcher:
    """Notifies when a torrent transitions into a completed state."""

    def __init__(self):
        self.url = os.environ.get("QBIT_URL", "").rstrip("/")
        self.user = os.environ.get("QBIT_USER", "")
        self.password = os.environ.get("QBIT_PASS", "")
        self.client = httpx.Client(timeout=10)
        self.enabled = bool(self.url)

    def _login(self) -> bool:
        r = self.client.post(
            f"{self.url}/api/v2/auth/login",
            data={"username": self.user, "password": self.password},
            headers={"Referer": self.url},
        )
        return r.status_code == 200 and r.text == "Ok."

    def poll(self, apns: APNs, seen: dict) -> None:
        if not self.enabled:
            return
        try:
            r = self.client.get(f"{self.url}/api/v2/torrents/info")
            if r.status_code == 403:
                if not self._login():
                    return
                r = self.client.get(f"{self.url}/api/v2/torrents/info")
            torrents = r.json()
        except (httpx.HTTPError, json.JSONDecodeError):
            return

        done_states = {"uploading", "stalledUP", "pausedUP", "queuedUP", "forcedUP", "stoppedUP"}
        completed = seen.setdefault("qbit_completed", {})
        for t in torrents:
            h, state = t["hash"], t["state"]
            is_done = state in done_states or t.get("progress", 0) >= 1.0
            if is_done and completed.get(h) is False:
                broadcast(apns, "torrents", "Torrent finished",
                          t.get("name", h)[:120])
            # Only flag not-done torrents so first sight of an already-seeded
            # torrent doesn't notify.
            if h not in completed or not is_done:
                completed[h] = is_done
        # Drop hashes qBit no longer reports.
        current = {t["hash"] for t in torrents}
        for h in list(completed):
            if h not in current:
                del completed[h]


class PromWatcher:
    """CPU + RAID threshold alerts with simple rising-edge de-dup."""

    def __init__(self):
        self.url = os.environ.get("PROM_URL", "").rstrip("/")
        self.client = httpx.Client(timeout=10)
        self.enabled = bool(self.url)

    def _instant(self, query: str):
        try:
            r = self.client.get(f"{self.url}/api/v1/query", params={"query": query})
            results = r.json()["data"]["result"]
            return float(results[0]["value"][1]) if results else None
        except Exception:
            return None

    def poll(self, apns: APNs, seen: dict) -> None:
        if not self.enabled:
            return
        cpu = self._instant(
            '100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)'
        )
        if cpu is not None:
            was_high = seen.get("cpu_high", False)
            is_high = cpu >= CPU_THRESHOLD
            if is_high and not was_high:
                broadcast(apns, "alerts", "High CPU on home server",
                          f"CPU at {cpu:.0f}% (threshold {CPU_THRESHOLD:.0f}%)")
            seen["cpu_high"] = is_high

        degraded = self._instant("node_md_disks{state=\"failed\"}")
        if degraded is not None:
            was_bad = seen.get("raid_bad", False)
            is_bad = degraded > 0
            if is_bad and not was_bad:
                broadcast(apns, "alerts", "RAID degraded",
                          f"{int(degraded)} failed disk(s) in md array")
            seen["raid_bad"] = is_bad


class ProbeWatcher:
    """HTTP up/down probes with edge-triggered notifications both ways."""

    def __init__(self):
        raw = os.environ.get("PROBE_URLS", "")
        self.probes = {}
        for pair in raw.split(","):
            if "=" in pair:
                name, url = pair.split("=", 1)
                self.probes[name.strip()] = url.strip()
        self.client = httpx.Client(timeout=8)

    def poll(self, apns: APNs, seen: dict) -> None:
        states = seen.setdefault("probe_up", {})
        for name, url in self.probes.items():
            try:
                up = self.client.get(url).status_code < 500
            except httpx.HTTPError:
                up = False
            was_up = states.get(name)
            if was_up is True and not up:
                broadcast(apns, "health", f"{name} is down",
                          f"No response from {url}")
            elif was_up is False and up:
                broadcast(apns, "health", f"{name} is back up", url)
            states[name] = up


# ---------------------------------------------------------------- HTTP API

class Handler(BaseHTTPRequestHandler):
    def _json(self, code: int, obj) -> None:
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/healthz":
            with _lock:
                count = len(load_json(TOKENS_FILE, {}))
            self._json(200, {"ok": True, "devices": count})
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            return self._json(400, {"error": "bad json"})
        token = (body.get("token") or "").strip().lower()
        if not token or any(c not in "0123456789abcdef" for c in token):
            return self._json(400, {"error": "bad token"})

        if self.path == "/register":
            topics = body.get("topics") or ["torrents", "alerts", "health"]
            with _lock:
                tokens = load_json(TOKENS_FILE, {})
                tokens[token] = {"topics": topics, "updated": int(time.time())}
                save_json(TOKENS_FILE, tokens)
            print(f"[register] {token[:8]}… topics={topics}", flush=True)
            self._json(200, {"ok": True})
        elif self.path == "/unregister":
            unregister_token(token)
            self._json(200, {"ok": True})
        else:
            self._json(404, {"error": "not found"})

    def log_message(self, fmt, *args):  # quiet default request logging
        pass


# ---------------------------------------------------------------- Main

def watch_loop() -> None:
    apns = APNs()
    qbit = QbitWatcher()
    prom = PromWatcher()
    probes = ProbeWatcher()
    seen = load_json(SEEN_FILE, {})
    print(f"[notifier] watching (qbit={qbit.enabled}, prom={prom.enabled}, "
          f"probes={list(probes.probes)}) every {POLL_SECONDS}s", flush=True)
    while True:
        qbit.poll(apns, seen)
        prom.poll(apns, seen)
        probes.poll(apns, seen)
        save_json(SEEN_FILE, seen)
        time.sleep(POLL_SECONDS)


def main() -> None:
    threading.Thread(target=watch_loop, daemon=True).start()
    port = int(os.environ.get("PORT", "8899"))
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"[notifier] registration API on :{port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
