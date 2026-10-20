#!/usr/bin/env bash
# End-to-end check of the AutoDJ handoff (#64): Icecast, Caddy (both hosts,
# TLS with its local CA), the auth stub, a stub playout endpoint and the
# playout service. A listener on each live mount (MP3, Opus) hears:
#   live (1000 Hz) -> AutoDJ (440 Hz) when the DJ drops -> live when the DJ
#   returns -> AutoDJ again when that set ends,
# on one connection. Reports the longest stall a listener sees at each switch,
# and checks AutoDJ fades in when the DJ drops (#109).
# Then a live source with another bitrate and sample rate than AutoDJ (step 4,
# informational: what a listener gets is documented in docs/reference/playout.md).
# Needs Docker with Compose, ffmpeg with libmp3lame and libopus, curl and python3.
set -euo pipefail

cd "$(dirname "$0")/.."
free_port() {
    python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}
run_id=${TEST_RUN_ID:-$$}
project=tcs-autodj-$run_id
https_port=$(free_port)
http_port=$(free_port)
# Inside the repository: Docker Desktop only shares some host paths.
work=$(mktemp -d "$PWD/.tmp-autodj.XXXXXX")
stub=$work/stub
env_file=$work/env
ca=$work/root.crt
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

secret=$(openssl rand -hex 16)
playout_password=$(openssl rand -hex 24)

# AutoDJ plays a 440 Hz tone; live sources play 1000 Hz.
ffmpeg -nostdin -loglevel error -f lavfi -i "sine=frequency=440:duration=60" -c:a libmp3lame -b:a 128k "$stub/tracks/a.mp3"
chmod 0644 "$stub/tracks/a.mp3"
python3 - "$stub" "$secret" <<'PY'
import hashlib, json, sys
from pathlib import Path
stub, secret = sys.argv[1:]
track = Path(stub, "tracks", "a.mp3")
tracks = [{"id": "a", "url": "http://playout-stub:9001/tracks/a.mp3",
           "sha256": hashlib.sha256(track.read_bytes()).hexdigest(), "title": "AutoDJ tone"}]
mp3 = {"format": "mp3", "bitrate_kbps": 128, "sample_rate": 44100, "channels": 2}
opus = {"format": "opus", "bitrate_kbps": 64, "sample_rate": 48000, "channels": 2}
state = {"stations": {"42": {"password": secret, "outputs": [mp3, opus], "tracks": tracks},
                      "43": {"password": secret, "outputs": [mp3], "tracks": tracks}}}
Path(stub, "state.json").write_text(json.dumps(state))
PY
chmod 0644 "$stub/state.json"

cat >"$work/stations.json" <<JSON
{"default": {"max_listeners": 10},
 "stations": {"42": {"max_listeners": 10, "formats": ["mp3", "opus"], "autodj": true},
              "43": {"max_listeners": 10, "formats": ["mp3"], "autodj": true}}}
JSON
chmod 0644 "$work/stations.json"

cat >"$env_file" <<ENV
ICECAST_SOURCE_PASSWORD=$(openssl rand -hex 24)
ICECAST_ADMIN_PASSWORD=$(openssl rand -hex 24)
ICECAST_SOURCE_AUTH_USER=icecast
ICECAST_SOURCE_AUTH_PASSWORD=$(openssl rand -hex 24)
ICECAST_PORT=$(free_port)
STUB_STATIONS=42:$secret,43:$secret
STATIONS_JSON=$work/stations.json
LISTEN_HOST=listen.localhost
INGEST_HOST=ingest.localhost
ACME_EMAIL=dev@example.com
CADDY_GLOBAL_OPTIONS=local_certs
CADDY_HTTP_PORT=$http_port
CADDY_HTTPS_PORT=$https_port
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
compose up -d "${build[@]}" --wait icecast caddy auth-stub playout-stub playout >/dev/null

for _ in $(seq 1 30); do
    compose cp caddy:/data/caddy/pki/authorities/local/root.crt "$ca" >/dev/null 2>&1 && break
    sleep 1
done

# *.localhost may resolve to ::1 while Docker publishes on 127.0.0.1.
pin=(--resolve "listen.localhost:$https_port:127.0.0.1")
listen=https://listen.localhost:$https_port

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
info() { echo "info - $*"; }

# Wait until AutoDJ publishes every mount: the listener then hears it on the
# idle live mount.
for mount in 42/live.mp3 42/live.opus 43/live.mp3; do
    for _ in $(seq 1 40); do
        [[ $(curl -s -o /dev/null -m 2 -w '%{size_download}' --cacert "$ca" "${pin[@]}" "$listen/stations/$mount" || true) -gt 0 ]] && break
        sleep 1
    done
done

# A live DJ for $2 seconds on mount $1: 1000 Hz, through the ingest host.
# $3: ffmpeg encoder arguments; $4: content type; $5: declared bitrate.
dj() {
    local mount=$1 seconds=$2 content_type=$4 kbps=$5
    read -r -a codec <<<"$3"
    ffmpeg -nostdin -loglevel error -re -f lavfi -i "sine=frequency=1000:duration=$seconds" "${codec[@]}" - 2>/dev/null |
        python3 tests/raw_source.py ingest.localhost "$https_port" "$mount" "$(cut -d/ -f3 <<<"$mount"):$secret" --ca "$ca" \
            --connect 127.0.0.1 --content-type "$content_type" --bitrate "$kbps" >/dev/null || true
}
dj_mp3() { dj "$1" "$2" "-ac 2 -ar ${3:-44100} -c:a libmp3lame -b:a ${4:-128}k -f mp3" audio/mpeg "${4:-128}"; }
dj_opus() { dj "$1" "$2" "-ac 2 -ar 48000 -c:a libopus -b:a 64k -f ogg" audio/ogg 64; }

# Record $2 for $3 seconds into $work/$1, and its size every 0.1 s
# ("<epoch seconds> <bytes>") into $work/$1.sizes. curl's exit code lands in
# $work/$1.exit: 28 means the connection stayed up until the timeout.
record() {
    local name=$1 mount=$2 seconds=$3
    (
        status=0
        curl -s -o "$work/$name" -m "$seconds" --cacert "$ca" "${pin[@]}" "$listen/stations/$mount" || status=$?
        echo "$status" >"$work/$name.exit"
    ) &
    pids+=($!)
    (
        end=$(($(date +%s) + seconds + 1))
        while (($(date +%s) < end)); do
            echo "$(date +%s.%N) $(stat -c %s "$work/$name" 2>/dev/null || echo 0)"
            sleep 0.1
        done >"$work/$name.sizes"
    ) &
    pids+=($!)
}
# Longest time, in seconds, without new bytes between epoch $2 and $3.
stall() {
    python3 - "$work/$1.sizes" "$2" "$3" <<'PY'
import sys
path, start, end = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
rows = [tuple(map(float, line.split())) for line in open(path) if line.strip()]
longest, last_t, last_size = 0.0, None, None
for t, size in rows:
    if t < start or t > end:
        last_t, last_size = (t, size) if t < start else (last_t, last_size)
        continue
    if last_size is None or size > last_size:
        last_t, last_size = t, size
    else:
        longest = max(longest, t - last_t)
print(f"{longest:.1f}")
PY
}
timeline() { python3 tests/tone_timeline.py "$work/$1"; }

# Steps 1-3, both formats at once:
#   0 s DJ starts (14 s), 3 s listeners connect (40 s), ~14 s DJ stops,
#   24 s DJ returns (14 s), ~38 s DJ stops again: back to AutoDJ until the
#   listeners end at 43 s.
dj_mp3 /stations/42/live.mp3 14 &
pids+=($!)
dj_opus /stations/42/live.opus 14 &
pids+=($!)
sleep 3
record mp3 42/live.mp3 40
record opus 42/live.opus 40
sleep 11
drop=$(date +%s.%N)
sleep 10
back=$(date +%s.%N)
dj_mp3 /stations/42/live.mp3 14 &
pids+=($!)
dj_opus /stations/42/live.opus 14 &
pids+=($!)
sleep 21
wait_files() { for _ in $(seq 1 20); do [[ -f $work/mp3.exit && -f $work/opus.exit ]] && return; sleep 1; done; }
wait_files

for fmt in mp3 opus; do
    check "$fmt: one connection for the whole test (no reconnect)" 28 "$(cat "$work/$fmt.exit" 2>/dev/null || echo none)"
    check "$fmt: live, AutoDJ when the DJ drops, live when the DJ returns, AutoDJ again" "L A L A" "$(timeline "$fmt")"
    to_autodj=$(stall "$fmt" "$drop" "$back")
    to_live=$(stall "$fmt" "$back" "$(python3 -c "print($back + 12)")")
    # AutoDJ fades in (#109): its first 0.3 s at least 4 dB under its level 2.5 s later, at both switches.
    levels=$(python3 tests/tone_timeline.py "$work/$fmt" --fade-in)
    check "$fmt: AutoDJ fades in at each switch from live (${levels:-none} dB)" yes \
        "$(python3 -c "import sys; v = [float(x) for x in sys.argv[1].split()]; print('yes' if len(v) == 2 and max(v) <= -4 else 'no')" "$levels")"
    check "$fmt: longest stall at the switch to AutoDJ under 5 s (${to_autodj} s)" yes \
        "$(python3 -c "print('yes' if $to_autodj < 5 else 'no')")"
    check "$fmt: longest stall at the switch back to live under 5 s (${to_live} s)" yes \
        "$(python3 -c "print('yes' if $to_live < 5 else 'no')")"
done

# Step 4 (informational): a live source at 64 kbps / 48 kHz, AutoDJ at
# 128 kbps / 44.1 kHz on station 43.
dj_mp3 /stations/43/live.mp3 10 48000 64 &
pids+=($!)
sleep 2
record mismatch 43/live.mp3 20
sleep 21
info "mismatch (live 64 kbps 48 kHz, AutoDJ 128 kbps 44.1 kHz): timeline $(timeline mismatch)"
info "mismatch: MP3 frames received: $(python3 tests/tone_timeline.py "$work/mismatch" --mp3-frames)"
info "mismatch: ffmpeg decode errors: $(ffmpeg -nostdin -v error -i "$work/mismatch" -f null - 2>&1 | wc -l)"

exit "$failures"
