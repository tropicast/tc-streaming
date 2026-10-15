"""AutoDJ playout supervisor (#63).

Polls the control plane's playout endpoint (docs/reference/playout.md) and
runs one Liquidsoap process per AutoDJ station. Each process publishes the
station's playlist to its hidden /stations/<id>/autodj.<fmt> mounts (#62).

- Tracks are downloaded once into a cache keyed by their sha256, checked,
  and listed in a per-station m3u that Liquidsoap reloads on change: a new
  playlist never restarts the station.
- A change of outputs, shuffle mode or credential restarts that station
  only. Adding or removing a station never touches the others.
- When the endpoint is unreachable or refuses, the running stations keep
  playing what they have.
- Secrets (node credentials, station passwords, presigned URLs) are never
  logged or written to disk: the station password reaches Liquidsoap
  through its environment.

    playout-supervisor.py              run
    playout-supervisor.py healthcheck  exit 0 when the last loop is recent
"""

import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unicodedata
import urllib.error
import urllib.request

PLAYOUT_URL = os.environ.get("PLAYOUT_URL", "")
PLAYOUT_USER = os.environ.get("PLAYOUT_USER", "")
PLAYOUT_PASSWORD = os.environ.get("PLAYOUT_PASSWORD", "")
ICECAST_HOST = os.environ.get("PLAYOUT_ICECAST_HOST", "icecast")
ICECAST_PORT = int(os.environ.get("PLAYOUT_ICECAST_PORT", "8000"))
POLL_SECONDS = float(os.environ.get("PLAYOUT_POLL_SECONDS", "30"))
MAX_TRACK_BYTES = int(os.environ.get("PLAYOUT_MAX_TRACK_MB", "200")) * 1024 * 1024
CACHE_DIR = Path(os.environ.get("PLAYOUT_CACHE_DIR", "/var/cache/playout"))
STATE_DIR = Path(os.environ.get("PLAYOUT_STATE_DIR", "/run/playout"))
HEALTH_FILE = STATE_DIR / "healthy"
TICK_SECONDS = 2
# A Liquidsoap process that keeps exiting is restarted at most this often.
RESTART_BACKOFF = (5, 10, 30, 60)

STATION_ID = re.compile(r"^[A-Za-z0-9-]{1,64}$")
TRACK_ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
# Encoder settings Liquidsoap and the players accept.
FORMATS = {
    "mp3": {"sample_rates": {32000, 44100, 48000}, "bitrates": range(32, 321)},
    "opus": {"sample_rates": {48000}, "bitrates": range(6, 257)},
}
METADATA_LIMIT = 256


def log(message):
    print(f"[playout] {message}", flush=True)


# --- Desired state --------------------------------------------------------


class InvalidState(Exception):
    pass


def parse_state(data):
    """Validated stations from the endpoint's JSON. Raises InvalidState."""
    if not isinstance(data, dict) or not isinstance(data.get("stations"), dict):
        raise InvalidState("'stations' must be an object")
    stations = {}
    for station_id, station in data["stations"].items():
        where = f"station {station_id!r}"
        if not STATION_ID.match(station_id):
            raise InvalidState(f"{where}: invalid id")
        if not isinstance(station, dict):
            raise InvalidState(f"{where}: must be an object")
        password = station.get("password")
        if not isinstance(password, str) or not password or any(ord(c) < 0x20 for c in password):
            raise InvalidState(f"{where}: needs a nonempty password")
        shuffle = station.get("shuffle", False)
        if not isinstance(shuffle, bool):
            raise InvalidState(f"{where}: shuffle must be true or false")
        stations[station_id] = {
            "password": password,
            "shuffle": shuffle,
            "outputs": parse_outputs(where, station.get("outputs")),
            "tracks": parse_tracks(where, station.get("tracks")),
        }
    return stations


def parse_outputs(where, outputs):
    if not isinstance(outputs, list) or not outputs:
        raise InvalidState(f"{where}: needs at least one output")
    parsed, seen = [], set()
    for output in outputs:
        if not isinstance(output, dict):
            raise InvalidState(f"{where}: outputs must be objects")
        fmt = output.get("format")
        if fmt not in FORMATS or fmt in seen:
            raise InvalidState(f"{where}: unknown or repeated format {fmt!r}")
        seen.add(fmt)
        rules = FORMATS[fmt]
        bitrate, sample_rate, channels = (output.get(k) for k in ("bitrate_kbps", "sample_rate", "channels"))
        if not is_int(bitrate) or bitrate not in rules["bitrates"]:
            raise InvalidState(f"{where}: {fmt} bitrate_kbps out of range")
        if not is_int(sample_rate) or sample_rate not in rules["sample_rates"]:
            raise InvalidState(f"{where}: {fmt} sample_rate not supported")
        if channels not in (1, 2) or isinstance(channels, bool):
            raise InvalidState(f"{where}: {fmt} channels must be 1 or 2")
        parsed.append({"format": fmt, "bitrate_kbps": bitrate, "sample_rate": sample_rate, "channels": channels})
    return parsed


def parse_tracks(where, tracks):
    if not isinstance(tracks, list):
        raise InvalidState(f"{where}: tracks must be a list")
    parsed = []
    for track in tracks:
        if not isinstance(track, dict):
            raise InvalidState(f"{where}: tracks must be objects")
        track_id, sha, url = track.get("id"), track.get("sha256"), track.get("url")
        if not isinstance(track_id, str) or not TRACK_ID.match(track_id):
            raise InvalidState(f"{where}: invalid track id")
        if not isinstance(sha, str) or not SHA256.match(sha):
            raise InvalidState(f"{where}: track {track_id} needs a lowercase hex sha256")
        if not isinstance(url, str) or not url.startswith(("https://", "http://")):
            raise InvalidState(f"{where}: track {track_id} needs an http(s) url")
        parsed.append({
            "id": track_id,
            "sha256": sha,
            "url": url,
            "title": clean_text(track.get("title")),
            "artist": clean_text(track.get("artist")),
        })
    return parsed


def is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def clean_text(value):
    """Metadata as plain text: no control characters, bounded length."""
    if not isinstance(value, str):
        return ""
    text = "".join(c for c in value if unicodedata.category(c) not in ("Cc", "Cf", "Zl", "Zp"))
    return text[:METADATA_LIMIT]


# --- Control plane --------------------------------------------------------


class Endpoint:
    """GET the desired state, with ETag so an unchanged state costs nothing."""

    def __init__(self):
        token = base64.b64encode(f"{PLAYOUT_USER}:{PLAYOUT_PASSWORD}".encode()).decode()
        self.auth = f"Basic {token}"
        self.etag = None

    def fetch(self):
        """Stations, None when unchanged. Raises on any failure."""
        request = urllib.request.Request(PLAYOUT_URL, headers={"Authorization": self.auth, "Accept": "application/json"})
        if self.etag:
            request.add_header("If-None-Match", self.etag)
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                body = response.read(8 * 1024 * 1024 + 1)
                etag = response.headers.get("ETag")
        except urllib.error.HTTPError as error:
            if error.code == 304:
                return None
            raise RuntimeError(f"playout endpoint answered {error.code}") from None
        if len(body) > 8 * 1024 * 1024:
            raise RuntimeError("playout endpoint answer is larger than 8 MiB")
        try:
            stations = parse_state(json.loads(body))
        except (ValueError, InvalidState) as error:
            raise RuntimeError(f"playout endpoint sent an invalid state: {error}") from None
        self.etag = etag
        return stations


# --- Track cache ----------------------------------------------------------


def sniff_extension(path):
    """File type from the content, never from the URL or the control plane."""
    with open(path, "rb") as handle:
        head = handle.read(12)
    if head.startswith(b"ID3") or (len(head) > 1 and head[0] == 0xFF and head[1] & 0xE0 == 0xE0):
        return "mp3"
    if head.startswith(b"OggS"):
        return "ogg"
    if head.startswith(b"fLaC"):
        return "flac"
    if head.startswith(b"RIFF") and head[8:12] == b"WAVE":
        return "wav"
    if head[4:8] == b"ftyp":
        return "m4a"
    return None


def cached(sha):
    for path in CACHE_DIR.glob(f"{sha}.*"):
        return path
    return None


def heartbeat():
    HEALTH_FILE.write_text(str(int(time.time())))


def download(track):
    """Path of the track in the cache, downloading it if needed; None on failure."""
    # A first sync of a large library takes a while: the loop is still alive.
    heartbeat()
    path = cached(track["sha256"])
    if path:
        return path
    digest = hashlib.sha256()
    size = 0
    with tempfile.NamedTemporaryFile(dir=CACHE_DIR, prefix=".download-", delete=False) as tmp:
        try:
            request = urllib.request.Request(track["url"])
            with urllib.request.urlopen(request, timeout=30) as response:
                while chunk := response.read(256 * 1024):
                    size += len(chunk)
                    if size > MAX_TRACK_BYTES:
                        raise RuntimeError(f"larger than {MAX_TRACK_BYTES // (1024 * 1024)} MiB")
                    digest.update(chunk)
                    tmp.write(chunk)
            if digest.hexdigest() != track["sha256"]:
                raise RuntimeError("sha256 does not match")
            tmp.close()
            extension = sniff_extension(tmp.name)
            if not extension:
                raise RuntimeError("not an mp3, ogg, flac, wav or m4a file")
            path = CACHE_DIR / f"{track['sha256']}.{extension}"
            os.replace(tmp.name, path)
            return path
        except (OSError, RuntimeError, urllib.error.URLError) as error:
            # The presigned URL is a secret: name the track, never the URL.
            reason = error.reason if isinstance(error, urllib.error.URLError) else error
            log(f"track {track['id']}: download failed: {reason}")
            Path(tmp.name).unlink(missing_ok=True)
            return None


def evict(keep):
    for path in CACHE_DIR.iterdir():
        if path.name.split(".")[0] not in keep:
            path.unlink(missing_ok=True)


# --- Liquidsoap -----------------------------------------------------------


def liq_string(value):
    return json.dumps(value)  # a JSON string is a valid Liquidsoap string literal


def encoder(output):
    fmt, rate, channels, kbps = output["format"], output["sample_rate"], output["channels"], output["bitrate_kbps"]
    stereo = "true" if channels == 2 else "false"
    if fmt == "mp3":
        return f"%mp3(bitrate={kbps}, samplerate={rate}, stereo={stereo})"
    return f"%ogg(%opus(bitrate={kbps}, samplerate={rate}, channels={channels}))"


def script(station_id, station, playlist):
    """Liquidsoap script of one station. Holds no secret."""
    mode = "randomize" if station["shuffle"] else "normal"
    lines = [
        "settings.log.stdout.set(true)",
        "settings.log.file.set(false)",
        "settings.log.level.set(3)",
        "settings.init.allow_root.set(false)",
        'password = environment.get("AUTODJ_PASSWORD")',
        # mksafe: silence instead of a dropped source while a track loads.
        f'radio = mksafe(playlist(id={liq_string(station_id)}, mode="{mode}", '
        f'reload_mode="watch", mime_type="audio/x-mpegurl", {liq_string(str(playlist))}))',
    ]
    for output in station["outputs"]:
        fmt = output["format"]
        source = "mean(radio)" if output["channels"] == 1 else "radio"
        extra = ', format="audio/ogg"' if fmt == "opus" else ""
        lines.append(
            f"output.icecast(id={liq_string(f'{station_id}-{fmt}')}, {encoder(output)}{extra}, "
            f"host={liq_string(ICECAST_HOST)}, port={ICECAST_PORT}, "
            f"user={liq_string(station_id)}, password=password, "
            f"mount={liq_string(f'/stations/{station_id}/autodj.{fmt}')}, "
            f'name="AutoDJ", public=false, {source})'
        )
    return "\n".join(lines) + "\n"


def m3u(paths_and_tracks):
    lines = []
    for path, track in paths_and_tracks:
        annotations = ",".join(
            f"{key}={liq_string(track[key])}" for key in ("title", "artist") if track[key]
        )
        lines.append(f"annotate:{annotations}:{path}" if annotations else str(path))
    return "\n".join(lines) + "\n"


def write_if_changed(path, content):
    if path.exists() and path.read_text() == content:
        return False
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_text(content)
    os.replace(tmp, path)
    return True


class Station:
    def __init__(self, station_id):
        self.id = station_id
        self.dir = STATE_DIR / "stations" / station_id
        self.dir.mkdir(parents=True, exist_ok=True)
        self.process = None
        self.config = None  # what a restart is needed for: outputs, shuffle, password
        self.failures = 0
        self.next_start = 0.0

    def apply(self, station, playlist_content):
        config = (json.dumps(station["outputs"], sort_keys=True), station["shuffle"], station["password"])
        if write_if_changed(self.dir / "playlist.m3u", playlist_content) and self.running():
            log(f"station {self.id}: playlist updated")
        write_if_changed(self.dir / "station.liq", script(self.id, station, self.dir / "playlist.m3u"))
        if config != self.config:
            if self.running():
                log(f"station {self.id}: settings changed, restarting")
                self.stop()
            self.config = config
            self.password = station["password"]
            self.failures, self.next_start = 0, 0.0

    def running(self):
        return self.process is not None and self.process.poll() is None

    def supervise(self):
        if self.running():
            return
        if self.process is not None:
            code = self.process.returncode
            self.process = None
            delay = RESTART_BACKOFF[min(self.failures, len(RESTART_BACKOFF) - 1)]
            self.failures += 1
            self.next_start = time.monotonic() + delay
            log(f"station {self.id}: liquidsoap exited with {code}, restarting in {delay} s")
            return
        if time.monotonic() < self.next_start:
            return
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(self.dir), "AUTODJ_PASSWORD": self.password}
        self.process = subprocess.Popen(["liquidsoap", str(self.dir / "station.liq")], env=env, stdin=subprocess.DEVNULL)
        self.started = time.monotonic()
        log(f"station {self.id}: started")

    def check_stable(self):
        # A process that ran for a minute is healthy again.
        if self.running() and self.failures and time.monotonic() - self.started > 60:
            self.failures = 0

    def stop(self):
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.process = None


# --- Main loop ------------------------------------------------------------


class Supervisor:
    def __init__(self):
        self.endpoint = Endpoint()
        self.stations = {}
        self.stopping = False

    def reconcile(self, desired):
        keep = set()
        for station_id, station in sorted(desired.items()):
            paths = [(download(track), track) for track in station["tracks"]]
            paths = [(path, track) for path, track in paths if path]
            keep.update(path.name.split(".")[0] for path, _ in paths)
            if not paths:
                # Nothing to play: no AutoDJ source, so the live mount has no
                # fallback and listeners are not held on silence.
                if station_id in self.stations:
                    log(f"station {station_id}: no playable track, stopping")
                    self.remove(station_id)
                else:
                    log(f"station {station_id}: no playable track, not started")
                continue
            if station_id not in self.stations:
                self.stations[station_id] = Station(station_id)
            self.stations[station_id].apply(station, m3u(paths))
        for station_id in sorted(set(self.stations) - set(desired)):
            log(f"station {station_id}: removed")
            self.remove(station_id)
        evict(keep)

    def remove(self, station_id):
        station = self.stations.pop(station_id)
        station.stop()
        shutil.rmtree(station.dir, ignore_errors=True)

    def run(self):
        for name in ("PLAYOUT_URL", "PLAYOUT_USER", "PLAYOUT_PASSWORD"):
            if not os.environ.get(name):
                sys.exit(f"{name} must be set")
        if not PLAYOUT_URL.startswith(("http://", "https://")) or "@" in PLAYOUT_URL:
            sys.exit("PLAYOUT_URL must be an http(s) URL without credentials")
        for signum in (signal.SIGTERM, signal.SIGINT):
            signal.signal(signum, self.shutdown)
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        (STATE_DIR / "stations").mkdir(parents=True, exist_ok=True)
        # Partial downloads and stations of a previous run.
        for path in CACHE_DIR.glob(".download-*"):
            path.unlink(missing_ok=True)
        for path in (STATE_DIR / "stations").iterdir():
            shutil.rmtree(path, ignore_errors=True)
        log(f"polling the control plane every {POLL_SECONDS:g} s")
        next_poll, failing = 0.0, False
        while not self.stopping:
            if time.monotonic() >= next_poll:
                next_poll = time.monotonic() + POLL_SECONDS
                try:
                    desired = self.endpoint.fetch()
                    if failing:
                        log("playout endpoint reachable again")
                    failing = False
                    if desired is not None:
                        self.reconcile(desired)
                except (OSError, RuntimeError) as error:
                    reason = error.reason if isinstance(error, urllib.error.URLError) else error
                    if not failing:
                        log(f"cannot read the desired state, keeping {len(self.stations)} stations: {reason}")
                    failing = True
            for station in list(self.stations.values()):
                station.supervise()
                station.check_stable()
            heartbeat()
            time.sleep(TICK_SECONDS)
        for station in self.stations.values():
            station.stop()
        log("stopped")

    def shutdown(self, *_):
        self.stopping = True


def healthcheck():
    try:
        age = time.time() - int(HEALTH_FILE.read_text())
    except (OSError, ValueError):
        sys.exit(1)
    # The loop writes it every tick; a long first sync may delay it.
    sys.exit(0 if age < max(120, POLL_SECONDS * 2) else 1)


if __name__ == "__main__":
    if sys.argv[1:] == ["healthcheck"]:
        healthcheck()
    Supervisor().run()
