#!/usr/bin/env python3
"""Prometheus exporter for container state, via the container API.

Why this exists instead of cAdvisor
-----------------------------------
cAdvisor derives per-container metrics from cgroups. Under rootless Podman
— the common setup on a Mac mini — container cgroups live in a user slice
cAdvisor cannot enumerate, so it emits only the root cgroup: `id="/"`, no
`name` label, no per-container series. Measured on Podman Engine 5.7:
cAdvisor starts cleanly, registers the Podman factory, can read the socket,
and still reports exactly one series.

This exporter asks the Docker-compatible HTTP API instead. That API is
identical on Docker Desktop, OrbStack, Colima and Podman, so the same
container works everywhere with no cgroup access and no privileged mode.

Emits
-----
    container_running{name,image,stack}   1 running, 0 otherwise
    container_restarts{name}              restart count
    container_total                       containers known, any state
    container_exporter_up                 1 when the API answered

`container_running` is deliberately the name Shellpocket's Containers KPI
queries first, so the card works with no app-side change.
"""

import http.client
import json
import os
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SOCKET_PATH = os.environ.get("CONTAINER_SOCK", "/var/run/docker.sock")
LISTEN_PORT = int(os.environ.get("EXPORTER_PORT", "9101"))
# Pinned low: Podman advertises a much higher version but honours 1.41,
# and Docker has supported it since 19.03. Anything newer buys nothing here.
API_VERSION = "v1.41"


class UnixHTTPConnection(http.client.HTTPConnection):
    """HTTPConnection over a unix socket — the API is HTTP, not TCP."""

    def __init__(self, path, timeout=5):
        super().__init__("localhost", timeout=timeout)
        self._unix_path = path

    def connect(self):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(self.timeout)
        sock.connect(self._unix_path)
        self.sock = sock


def fetch_containers():
    conn = UnixHTTPConnection(SOCKET_PATH)
    try:
        conn.request("GET", f"/{API_VERSION}/containers/json?all=1")
        resp = conn.getresponse()
        if resp.status != 200:
            raise RuntimeError(f"API returned HTTP {resp.status}")
        return json.loads(resp.read())
    finally:
        conn.close()


def escape(value):
    """Escape a Prometheus label value."""
    return str(value).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def render():
    lines = [
        "# HELP container_running 1 if the container is running, 0 otherwise",
        "# TYPE container_running gauge",
    ]
    try:
        containers = fetch_containers()
    except Exception as exc:  # noqa: BLE001 - surfaced as a metric, not a crash
        print(f"scrape failed: {exc}", file=sys.stderr, flush=True)
        return "\n".join(
            lines
            + [
                "# HELP container_exporter_up 1 if the container API answered",
                "# TYPE container_exporter_up gauge",
                "container_exporter_up 0",
                "",
            ]
        )

    restarts = [
        "# HELP container_restarts Times the container has been restarted",
        "# TYPE container_restarts counter",
    ]
    running = 0

    for c in containers:
        names = c.get("Names") or []
        name = (names[0] if names else c.get("Id", "?")[:12]).lstrip("/")
        labels = c.get("Labels") or {}
        # compose.project groups a stack; fall back to a per-repo label so
        # the value is still useful outside compose.
        stack = (
            labels.get("com.docker.compose.project")
            or labels.get("io.podman.compose.project")
            or ""
        )
        is_running = 1 if c.get("State") == "running" else 0
        running += is_running

        label_str = (
            f'name="{escape(name)}",'
            f'image="{escape(c.get("Image", ""))}",'
            f'stack="{escape(stack)}"'
        )
        lines.append(f"container_running{{{label_str}}} {is_running}")
        restarts.append(
            f'container_restarts{{name="{escape(name)}"}} '
            f'{int(labels.get("restart_count", 0) or 0)}'
        )

    return "\n".join(
        lines
        + restarts
        + [
            "# HELP container_total Containers known to the runtime, any state",
            "# TYPE container_total gauge",
            f"container_total {len(containers)}",
            "# HELP container_exporter_up 1 if the container API answered",
            "# TYPE container_exporter_up gauge",
            "container_exporter_up 1",
            "",
        ]
    )


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802 - required by BaseHTTPRequestHandler
        if self.path.rstrip("/") in ("/metrics", ""):
            body = render().encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path.rstrip("/") == "/healthz":
            self.send_response(200)
            self.send_header("Content-Length", "3")
            self.end_headers()
            self.wfile.write(b"ok\n")
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *_args):
        """Silence per-request logging; Prometheus scrapes every 15s."""


if __name__ == "__main__":
    print(
        f"container-exporter listening on :{LISTEN_PORT}, socket {SOCKET_PATH}",
        flush=True,
    )
    ThreadingHTTPServer(("", LISTEN_PORT), Handler).serve_forever()
