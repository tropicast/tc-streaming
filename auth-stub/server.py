"""Local stand-in for the control-plane source auth endpoint.

Implements the contract in docs/source-auth.md for development and CI.
Never deploy it: credentials come from an environment variable.
"""

import base64
import hmac
import json
import os
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

MOUNT = re.compile(r"^/stations/(?P<station>[A-Za-z0-9-]{1,64})/live\.(mp3|opus)$")


def load_stations():
    """Parse STUB_STATIONS, e.g. "42:secret42,77:secret77"."""
    stations = {}
    for entry in os.environ.get("STUB_STATIONS", "").split(","):
        if entry:
            station, _, secret = entry.partition(":")
            stations[station] = secret
    return stations


STATIONS = load_stations()


def load_limits():
    """Station plans from the same stations.json Icecast uses (#8)."""
    path = os.environ.get("STUB_LIMITS_FILE", "")
    if not path or not os.path.exists(path):
        return {}
    with open(path) as handle:
        return json.load(handle).get("stations", {})


def declared_kbps(fields):
    """Bitrate the source declares (Ice-Bitrate, else Ice-Audio-Info)."""
    value = fields.get("header.ice-bitrate", "")
    if not value:
        match = re.search(r"(?:^|;)\s*(?:ice-)?bitrate=(\d+)", fields.get("header.ice-audio-info", ""))
        value = match.group(1) if match else ""
    return int(value) if value.isdigit() else None
EXPECTED_AUTH = "Basic " + base64.b64encode(
    f"{os.environ['STUB_ICECAST_USER']}:{os.environ['STUB_ICECAST_PASSWORD']}".encode()
).decode()


def allowed(fields):
    match = MOUNT.match(fields.get("mount", ""))
    if not match:
        return False, "mount outside /stations/{id}/live.(mp3|opus)"
    station = match["station"]
    secret = STATIONS.get(station)
    if secret is None or fields.get("user") != station:
        return False, "unknown station or wrong user"
    if not hmac.compare_digest(fields.get("pass", ""), secret):
        return False, "wrong password"
    limits = load_limits().get(station)
    if limits:
        if match.group(2) not in limits.get("formats", ["mp3", "opus"]):
            return False, f"format {match.group(2)} not in the station's plan"
        kbps = declared_kbps(fields)
        cap = limits.get("max_bitrate_kbps")
        if cap and kbps and kbps > cap:
            return False, f"bitrate {kbps} kbps above the plan's {cap} kbps"
    return True, ""


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if not hmac.compare_digest(self.headers.get("Authorization", ""), EXPECTED_AUTH):
            self.send_response(401)
            self.end_headers()
            return
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode()
        fields = {k: v[0] for k, v in parse_qs(body, keep_blank_values=True).items()}
        ok, reason = allowed(fields)
        print(f"{fields.get('action')} mount={fields.get('mount')} user={fields.get('user')} -> {'allow' if ok else 'deny: ' + reason}", flush=True)
        self.send_response(200)
        if ok:
            self.send_header("icecast-auth-user", "1")
        else:
            self.send_header("icecast-auth-message", reason)
        self.end_headers()

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 9000), Handler).serve_forever()
