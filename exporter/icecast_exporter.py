"""Prometheus exporter for the streaming node (#10).

Serves /metrics on :9100: on the internal Docker network for Alloy, and on the
node's private-network address for the control plane (tc-dashboard#10), which
reads listeners and egress here instead of holding Icecast credentials.
- Icecast stats from /admin/stats.xml: listeners and bytes per station.
- The node's month-to-date egress and included quota from the Hetzner
  Cloud API, when HCLOUD_READ_TOKEN is set (use a read-only token).

Environment:
  ICECAST_URL           default http://icecast:8000
  ICECAST_ADMIN_USER    default admin
  ICECAST_ADMIN_PASSWORD
  HCLOUD_READ_TOKEN     optional, read-only Hetzner Cloud API token
  HCLOUD_SERVER_NAME    server to read traffic for, e.g. tc-stream-1
"""

import base64
import json
import os
import re
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ICECAST_URL = os.environ.get("ICECAST_URL", "http://icecast:8000").rstrip("/")
ADMIN_AUTH = "Basic " + base64.b64encode(
    f"{os.environ.get('ICECAST_ADMIN_USER', 'admin')}:{os.environ.get('ICECAST_ADMIN_PASSWORD', '')}".encode()
).decode()
HCLOUD_TOKEN = os.environ.get("HCLOUD_READ_TOKEN", "")
HCLOUD_SERVER = os.environ.get("HCLOUD_SERVER_NAME", "")
HCLOUD_API = os.environ.get("HCLOUD_API", "https://api.hetzner.cloud/v1").rstrip("/")
HCLOUD_TTL = 300  # seconds; Hetzner updates traffic counters slowly
STATION = re.compile(r"^/stations/(?P<station>[A-Za-z0-9-]+)/live\.(?P<format>mp3|opus)$")

_hcloud_cache = {"at": 0.0, "lines": []}


def escape(value):
    return str(value).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def number(text, default=0.0):
    try:
        return float(text)
    except (TypeError, ValueError):
        return default


def icecast_lines():
    """Metrics from Icecast's admin stats, or icecast_up 0."""
    request = urllib.request.Request(f"{ICECAST_URL}/admin/stats.xml", headers={"Authorization": ADMIN_AUTH})
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            root = ET.fromstring(response.read())
    except Exception:  # unreachable, auth error or bad XML: Icecast is down for us
        return ["# TYPE icecast_up gauge", "icecast_up 0"]

    lines = [
        "# HELP icecast_up 1 if Icecast answered the stats request.",
        "# TYPE icecast_up gauge",
        "icecast_up 1",
    ]
    for name, help_text in [
        ("listeners", "Listeners on all mounts."),
        ("clients", "All connected clients."),
        ("sources", "Live sources."),
    ]:
        lines += [f"# HELP icecast_{name} {help_text}", f"# TYPE icecast_{name} gauge",
                  f"icecast_{name} {number(root.findtext(name))}"]

    per_mount = {
        "icecast_mount_up": ("gauge", "1 while the station's source is live.", lambda s: 1),
        "icecast_mount_listeners": ("gauge", "Current listeners.", lambda s: number(s.findtext("listeners"))),
        "icecast_mount_listener_peak": ("gauge", "Peak listeners since the source started.",
                                        lambda s: number(s.findtext("listener_peak"))),
        "icecast_mount_slow_listeners": ("gauge", "Listeners falling behind.",
                                         lambda s: number(s.findtext("slow_listeners"))),
        "icecast_mount_sent_bytes_total": ("counter", "Bytes sent to listeners since the source started.",
                                           lambda s: number(s.findtext("total_bytes_sent"))),
        "icecast_mount_read_bytes_total": ("counter", "Bytes received from the source since it started.",
                                           lambda s: number(s.findtext("total_bytes_read"))),
        "icecast_mount_start_timestamp_seconds": ("gauge", "When the source connected.", stream_start),
        "icecast_mount_bitrate_kbps": ("gauge", "Source bitrate: as declared (ice-bitrate), else measured.",
                                       source_bitrate),
    }
    sources = root.findall("source")
    for metric, (kind, help_text, value) in per_mount.items():
        lines += [f"# HELP {metric} {help_text}", f"# TYPE {metric} {kind}"]
        for source in sources:
            mount = source.get("mount", "")
            match = STATION.match(mount)
            labels = f'mount="{escape(mount)}"'
            if match:
                labels += f',station="{escape(match["station"])}",format="{match["format"]}"'
            lines.append(f"{metric}{{{labels}}} {value(source)}")
    return lines


def stream_start(source):
    text = source.findtext("stream_start_iso8601") or ""
    try:
        return datetime.strptime(text, "%Y-%m-%dT%H:%M:%S%z").timestamp()
    except ValueError:
        return 0


def source_bitrate(source):
    """The declared bitrate, or the average incoming rate once the source ran 30 s; 0 if unknown."""
    declared = number(source.findtext("bitrate"))
    if declared <= 0:
        match = re.search(r"(?:^|;)\s*(?:ice-)?bitrate=(\d+)", source.findtext("audio_info") or "")
        declared = number(match.group(1)) if match else 0
    if declared > 0:
        return declared
    started = stream_start(source)
    seconds = time.time() - started if started else 0
    # Earlier the whole-second start time and connection setup skew the average.
    if seconds < 30:
        return 0
    return round(number(source.findtext("total_bytes_read")) * 8 / 1000 / seconds, 1)


def hcloud_lines():
    """Month-to-date egress from the Hetzner API, cached for HCLOUD_TTL."""
    if not (HCLOUD_TOKEN and HCLOUD_SERVER):
        return []
    if time.time() - _hcloud_cache["at"] < HCLOUD_TTL:
        return _hcloud_cache["lines"]
    request = urllib.request.Request(
        f"{HCLOUD_API}/servers?name={urllib.parse.quote(HCLOUD_SERVER)}",
        headers={"Authorization": f"Bearer {HCLOUD_TOKEN}"},
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            server = json.load(response)["servers"][0]
        labels = f'server="{escape(HCLOUD_SERVER)}"'
        lines = [
            "# HELP hetzner_up 1 if the Hetzner API answered.",
            "# TYPE hetzner_up gauge",
            "hetzner_up 1",
            "# HELP hetzner_server_outgoing_traffic_bytes Outgoing traffic in the current billing period.",
            "# TYPE hetzner_server_outgoing_traffic_bytes gauge",
            f"hetzner_server_outgoing_traffic_bytes{{{labels}}} {number(server.get('outgoing_traffic'))}",
            "# HELP hetzner_server_ingoing_traffic_bytes Incoming traffic in the current billing period.",
            "# TYPE hetzner_server_ingoing_traffic_bytes gauge",
            f"hetzner_server_ingoing_traffic_bytes{{{labels}}} {number(server.get('ingoing_traffic'))}",
            "# HELP hetzner_server_included_traffic_bytes Traffic included in the server price.",
            "# TYPE hetzner_server_included_traffic_bytes gauge",
            f"hetzner_server_included_traffic_bytes{{{labels}}} {number(server.get('included_traffic'))}",
        ]
    except Exception:
        lines = ["# TYPE hetzner_up gauge", "hetzner_up 0"]
    _hcloud_cache.update(at=time.time(), lines=lines)
    return lines


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/metrics":
            self.send_response(404)
            self.end_headers()
            return
        body = ("\n".join(icecast_lines() + hcloud_lines()) + "\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 9100), Handler).serve_forever()
