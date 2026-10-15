#!/usr/bin/env bash
# End-to-end check of the AutoDJ playout service (#63): Icecast, the auth
# stub, a stub playout endpoint with its track server, and the playout
# image. Listeners connect to the live mounts, which have no DJ, so they hear
# AutoDJ through the fallback (#62).
# Needs Docker with Compose, ffmpeg with libmp3lame, curl and python3.
set -euo pipefail

cd "$(dirname "$0")/.."
free_port() {
    python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}
run_id=${TEST_RUN_ID:-$$}
project=tcs-playout-$run_id
port=$(free_port)
# Inside the repository: Docker Desktop only shares some host paths.
work=$(mktemp -d "$PWD/.tmp-playout.XXXXXX")
stub=$work/stub
env_file=$work/env
pids=()
# shellcheck disable=SC2317,SC2329 # called by the EXIT trap
cleanup() {
    kill "${pids[@]}" 2>/dev/null || true
    [[ -n ${KEEP:-} ]] || compose down -v >/dev/null 2>&1
    rm -rf "$work"
}
trap cleanup EXIT
mkdir -p "$stub/tracks"
chmod 0755 "$work" "$stub" "$stub/tracks"

admin_password=$(openssl rand -hex 24)
playout_password=$(openssl rand -hex 24)
declare -A secret
for station in 42 77 88 99; do secret[$station]=$(openssl rand -hex 16); done
wrong99=$(openssl rand -hex 16)

# Tracks: an MP3 and a FLAC (types are sniffed from the content), and one
# whose sha256 the control plane gets wrong.
ffmpeg -nostdin -loglevel error -f lavfi -i "sine=frequency=440:duration=20" -c:a libmp3lame -b:a 128k "$stub/tracks/t1.mp3"
ffmpeg -nostdin -loglevel error -f lavfi -i "sine=frequency=660:duration=20" "$stub/tracks/t2.flac"
cp "$stub/tracks/t1.mp3" "$stub/tracks/bad.mp3"
chmod 0644 "$stub/tracks"/*

# $1: the station ids to include, e.g. "42 77 99"; $2: 42's track ids.
write_state() {
    python3 - "$stub" "$1" "${2:-t1 t2}" "${secret[42]}" "${secret[77]}" "${secret[88]}" "$wrong99" <<'PY'
import hashlib, json, sys
from pathlib import Path
stub, ids, tracks42, s42, s77, s88, w99 = sys.argv[1:]
tracks = Path(stub, "tracks")
def track(track_id, name, sha=None):
    return {"id": track_id, "url": f"http://playout-stub:9001/tracks/{name}",
            "sha256": sha or hashlib.sha256((tracks / name).read_bytes()).hexdigest(),
            "title": f"Track {track_id}", "artist": "Tropicast"}
files = {"t1": "t1.mp3", "t2": "t2.flac"}
stereo = lambda fmt, kbps, rate: {"format": fmt, "bitrate_kbps": kbps, "sample_rate": rate, "channels": 2}
stations = {
    "42": {"password": s42, "outputs": [stereo("mp3", 128, 44100), stereo("opus", 64, 48000)],
           "tracks": [track(t, files[t]) for t in tracks42.split()]},
    "77": {"password": s77, "shuffle": True,
           "outputs": [{"format": "mp3", "bitrate_kbps": 64, "sample_rate": 44100, "channels": 1}],
           "tracks": [track("t1", "t1.mp3"), track("bad", "bad.mp3", "0" * 64)]},
    "88": {"password": s88, "outputs": [stereo("mp3", 128, 44100)], "tracks": [track("t2", "t2.flac")]},
    "99": {"password": w99, "outputs": [stereo("mp3", 128, 44100)], "tracks": [track("t1", "t1.mp3")]},
}
state = {"stations": {i: stations[i] for i in ids.split()}}
# Overwrite in place: the stub reads it through a bind mount.
with open(Path(stub, "state.json"), "w") as handle:
    json.dump(state, handle)
PY
    chmod 0644 "$stub/state.json"
}
write_state "42 77 99"

cat >"$work/stations.json" <<JSON
{"default": {"max_listeners": 10},
 "stations": {"42": {"max_listeners": 10, "formats": ["mp3", "opus"], "autodj": true},
              "77": {"max_listeners": 10, "formats": ["mp3"], "autodj": true},
              "88": {"max_listeners": 10, "formats": ["mp3"], "autodj": true},
              "99": {"max_listeners": 10, "formats": ["mp3"], "autodj": true}}}
JSON
chmod 0644 "$work/stations.json"

cat >"$env_file" <<ENV
ICECAST_SOURCE_PASSWORD=$(openssl rand -hex 24)
ICECAST_ADMIN_PASSWORD=$admin_password
ICECAST_SOURCE_AUTH_USER=icecast
ICECAST_SOURCE_AUTH_PASSWORD=$(openssl rand -hex 24)
ICECAST_PORT=$port
STUB_STATIONS=42:${secret[42]},77:${secret[77]},88:${secret[88]},99:${secret[99]}
STATIONS_JSON=$work/stations.json
LISTEN_HOST=listen.localhost
INGEST_HOST=ingest.localhost
ACME_EMAIL=dev@example.com
COMPOSE_PROFILES=autodj
PLAYOUT_URL=http://playout-stub:9001/playout
PLAYOUT_USER=playout
PLAYOUT_PASSWORD=$playout_password
PLAYOUT_POLL_SECONDS=2
PLAYOUT_STUB_DIR=$stub
ENV

compose() { docker compose -p "$project" --env-file "$env_file" -f compose.yaml -f tests/playout.compose.yaml "$@"; }
build=(--build)
[[ -n ${E2E_PREBUILT:-} ]] && build=()
compose up -d "${build[@]}" --wait icecast auth-stub playout-stub playout >/dev/null

failures=0
check() {
    local name=$1 expected=$2 actual=$3
    if [[ $expected == "$actual" ]]; then
        echo "ok   - $name"
    else
        echo "FAIL - $name (expected $expected, got $actual)"
        failures=$((failures + 1))
    fi
}
# Mounts with a connected source, from Icecast's admin API.
mounts() {
    curl -s -m 3 -u "admin:$admin_password" "http://127.0.0.1:$port/admin/listmounts" |
        grep -o 'mount="[^"]*"' | cut -d'"' -f2 || true
}
mounted() { [[ $(mounts | grep -cx -- "$1" || true) -gt 0 ]] && echo yes || echo no; }
# Wait up to $2 seconds for mount $1 to be (yes) or not be (no) connected.
wait_mount() {
    local mount=$1 want=$2 seconds=${3:-40}
    for _ in $(seq 1 "$seconds"); do
        [[ $(mounted "$mount") == "$want" ]] && { echo "$want"; return; }
        sleep 1
    done
    mounted "$mount"
}
playout_logs() { compose logs --no-log-prefix playout 2>/dev/null; }
# yes when service $1's log has the fixed string $2. Counts instead of grep -q:
# an early exit would fail the pipeline under pipefail.
logged() {
    [[ $(compose logs --no-log-prefix "$1" 2>/dev/null | grep -cF -- "$2" || true) -gt 0 ]] && echo yes || echo no
}
size() { stat -c %s "$work/$1" 2>/dev/null || echo 0; }
# Bytes a listener receives in 5 seconds on mount $1.
listen_bytes() { curl -s -o /dev/null -m 5 -w '%{size_download}' "http://127.0.0.1:$port$1" || true; }

check "station 42: AutoDJ publishes MP3" yes "$(wait_mount /stations/42/autodj.mp3 yes)"
check "station 42: AutoDJ publishes Opus" yes "$(wait_mount /stations/42/autodj.opus yes)"
check "station 77: AutoDJ publishes MP3" yes "$(wait_mount /stations/77/autodj.mp3 yes)"

bytes=$(listen_bytes /stations/42/live.mp3)
check "a listener on 42's idle live mount hears AutoDJ (>= 60 KB in 5 s at 128 kbps)" yes \
    "$([[ ${bytes:-0} -ge 60000 ]] && echo yes || echo no)"
curl -s -o "$work/42.ogg" -m 4 "http://127.0.0.1:$port/stations/42/live.opus" || true
check "station 42: Opus output decodes as opus" opus \
    "$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$work/42.ogg" 2>/dev/null || echo none)"
curl -s -o "$work/77.mp3" -m 4 "http://127.0.0.1:$port/stations/77/live.mp3" || true
check "station 77: mono output" 1 \
    "$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of csv=p=0 "$work/77.mp3" 2>/dev/null || echo none)"
check "station 77: the track with a wrong sha256 is refused" yes \
    "$(logged playout 'track bad: download failed: sha256 does not match')"

check "station 99: a wrong AutoDJ credential is refused" no "$(mounted /stations/99/autodj.mp3)"
check "station 99: the refusal comes from source auth" yes \
    "$(logged auth-stub 'mount=/stations/99/autodj.mp3 user=99 -> deny: wrong password')"

# Adding and removing stations, and a new playlist, leave the others alone.
curl -s -o "$work/long" -m 60 "http://127.0.0.1:$port/stations/42/live.mp3" &
pids+=($!)
sleep 3
write_state "42 88 99"
check "added station 88 starts" yes "$(wait_mount /stations/88/autodj.mp3 yes)"
check "removed station 77 stops" no "$(wait_mount /stations/77/autodj.mp3 no)"
write_state "42 88 99" "t1"
for _ in $(seq 1 20); do [[ $(logged playout 'station 42: playlist updated') == yes ]] && break; sleep 1; done
check "station 42: a new playlist is applied" yes "$(logged playout 'station 42: playlist updated')"
before=$(size long)
sleep 3
check "station 42's listener keeps receiving audio" yes "$([[ $(size long) -gt $before ]] && echo yes || echo no)"
check "station 42 was never restarted" 1 "$(playout_logs | grep -c 'station 42: started' || true)"

# The control plane goes away: stations keep playing.
compose stop playout-stub >/dev/null 2>&1
sleep 6
check "endpoint down: the failure is logged once" 1 \
    "$(playout_logs | grep -c 'cannot read the desired state, keeping 3 stations' || true)"
check "endpoint down: station 42 keeps playing" yes "$(mounted /stations/42/autodj.mp3)"
check "playout is healthy" healthy \
    "$(docker inspect -f '{{.State.Health.Status}}' "$(compose ps -q playout)")"

logs=$(compose logs playout playout-stub icecast 2>&1)
leaked=clean
for value in "$playout_password" "$wrong99" "${secret[42]}" "${secret[77]}" "${secret[88]}" "/tracks/t1.mp3"; do
    grep -qF -- "$value" <<<"$logs" && leaked=leaked
done
check "logs contain no credential or track URL" clean "$leaked"

exit "$failures"
