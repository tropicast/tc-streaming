#!/usr/bin/env bash
# Source-to-listener latency, per stage (#84): Icecast, Caddy (both hosts,
# TLS with its local CA), the auth stub, a stub playout endpoint and the
# playout service, like tests/autodj.sh. Where autodj.sh checks that the
# switches happen, this measures how late the listener hears them.
#
#   1. AutoDJ warm-up: the station gets a library of 200 tracks while the
#      playout service runs with its default poll. Time to the supervisor's
#      "started" and to the first AutoDJ byte on the live mount. Then the
#      playout service restarts with its cache warm: time to the first byte.
#   2. A DJ on air for 35 s (MP3 128 kbps and Opus 64 kbps on one station),
#      a listener per format from 12 s, AutoDJ for 10 s, the DJ again for
#      15 s, AutoDJ to the end. latency.py turns the recordings into delays.
#   3. A DJ whose connection dies without closing (a lost uplink): after
#      10 s the source sends nothing more but keeps its connection open.
#      Icecast's <source-timeout> decides when listeners get AutoDJ.
#
# Each delay has a budget (LATENCY_MAX_*, seconds); over budget fails. The
# budgets start at what main measures and go down as #83's sub-issues land.
# Needs Docker with Compose, ffmpeg with libmp3lame and libopus, curl and python3.
set -euo pipefail

# Budgets, seconds (docs/reference/latency.md). With #85's bursts and 100 ms
# Ogg pages on both the DJ's and AutoDJ's Opus (#93): delays and switches
# 0.3-0.8 s; a dead source 3-4.5 s. Switches to AutoDJ include part of its
# 2 s fade-in (#109): it is heard once loud enough to tell its tone apart.
: "${LATENCY_MAX_AUTODJ_START:=10}"   # library published to first AutoDJ byte
: "${LATENCY_MAX_AUTODJ_RESTART:=5}"  # playout restarted, cache warm, to first AutoDJ byte
: "${LATENCY_MAX_FIRST_AUDIO:=1}"    # listener start to the first complete frame
: "${LATENCY_MAX_DELAY:=1.5}"        # microphone to ear, live, at connect and steady
: "${LATENCY_MAX_SWITCH:=1.5}"       # DJ starts to the listener hearing it
: "${LATENCY_MAX_TO_AUTODJ:=2.5}"    # DJ stops to the listener hearing AutoDJ (fading in)
: "${LATENCY_MAX_AFTER_RETURN:=1.5}" # microphone to ear, after the DJ reconnects
: "${LATENCY_MAX_DEAD_SOURCE:=7}"    # a DJ's connection dies to AutoDJ heard (fading in)

cd "$(dirname "$0")/.."
free_port() {
    python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}
run_id=${TEST_RUN_ID:-$$}
project=tcs-latency-$run_id
https_port=$(free_port)
http_port=$(free_port)
# Inside the repository: Docker Desktop only shares some host paths.
work=$(mktemp -d "$PWD/.tmp-latency.XXXXXX")
stub=$work/stub
env_file=$work/env
ca=$work/root.crt
pids=()
# shellcheck disable=SC2317,SC2329 # called by the EXIT trap
cleanup() {
    kill "${pids[@]}" 2>/dev/null || true
    [[ -n ${KEEP:-} ]] || { compose down -v >/dev/null 2>&1; rm -rf "$work"; }
}
trap cleanup EXIT
mkdir -p "$stub/tracks"
chmod 0755 "$work" "$stub" "$stub/tracks"

secret=$(openssl rand -hex 16)
playout_password=$(openssl rand -hex 24)

# A library of 200 tracks of 10 s at 440 Hz: AutoDJ. Each one differs (an
# ID3v1 tag with its number), as tracks of a real library do, so the cache
# keeps 200 files.
ffmpeg -nostdin -loglevel error -f lavfi -i "sine=frequency=440:duration=10" -c:a libmp3lame -b:a 128k "$work/tone.mp3"
python3 - "$work/tone.mp3" "$stub/tracks" <<'PY'
import sys
from pathlib import Path
tone, tracks = Path(sys.argv[1]).read_bytes(), Path(sys.argv[2])
for i in range(1, 201):
    tag = b"TAG" + f"Track {i}".encode().ljust(30, b"\0") + bytes(95)
    path = tracks / f"t{i:03}.mp3"
    path.write_bytes(tone + tag)
    path.chmod(0o644)
PY
# No AutoDJ station at first: step 1 publishes the library.
echo '{"stations": {}}' >"$stub/state.json"
chmod 0644 "$stub/state.json"
publish_library() {
    python3 - "$stub" "$secret" <<'PY'
import hashlib, json, sys
from pathlib import Path
stub, secret = sys.argv[1:]
tracks = [{"id": p.stem, "url": f"http://playout-stub:9001/tracks/{p.name}",
           "sha256": hashlib.sha256(p.read_bytes()).hexdigest(), "title": p.stem}
          for p in sorted(Path(stub, "tracks").glob("*.mp3"))]
mp3 = {"format": "mp3", "bitrate_kbps": 128, "sample_rate": 44100, "channels": 2}
opus = {"format": "opus", "bitrate_kbps": 64, "sample_rate": 48000, "channels": 2}
state = {"stations": {"42": {"password": secret, "outputs": [mp3, opus], "tracks": tracks}}}
# In place, not a rename: Docker Desktop's file sharing keeps showing the old file.
Path(stub, "state.json").write_text(json.dumps(state))
PY
}

cat >"$work/stations.json" <<JSON
{"default": {"max_listeners": 10},
 "stations": {"42": {"max_listeners": 10, "max_bitrate_kbps": 128, "formats": ["mp3", "opus"], "autodj": true}}}
JSON
chmod 0644 "$work/stations.json"

# PLAYOUT_POLL_SECONDS is left at its default: the warm-up includes it.
cat >"$env_file" <<ENV
ICECAST_SOURCE_PASSWORD=$(openssl rand -hex 24)
ICECAST_ADMIN_PASSWORD=$(openssl rand -hex 24)
ICECAST_SOURCE_AUTH_USER=icecast
ICECAST_SOURCE_AUTH_PASSWORD=$(openssl rand -hex 24)
ICECAST_PORT=$(free_port)
STUB_STATIONS=42:$secret
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
declare -A measured
# A delay against its budget: "ok", or "FAIL" and a failure.
budget() {
    local name=$1 value=$2 max=$3
    measured[$name]=$value
    if [[ -z $value || $value == None ]]; then
        echo "FAIL - $name: not measured"
        failures=$((failures + 1))
    elif python3 -c "import sys; sys.exit(0 if $value <= $max else 1)"; then
        echo "ok   - $name: $value s (budget $max s)"
    else
        echo "FAIL - $name: $value s (budget $max s)"
        failures=$((failures + 1))
    fi
}
check() {
    local name=$1 expected=$2 actual=$3
    if [[ $expected == "$actual" ]]; then
        echo "ok   - $name"
    else
        echo "FAIL - $name (expected $expected, got $actual)"
        failures=$((failures + 1))
    fi
}
now() { date +%s.%N; }
elapsed() { python3 -c "print(f'{$2 - $1:.2f}')"; }

# --- 1. AutoDJ warm-up --------------------------------------------------------

# Let the supervisor's first poll find no station, so the next one counts.
sleep 2
enabled=$(now)
publish_library
on_air=
for _ in $(seq 1 600); do
    if [[ $(curl -sf -o /dev/null -m 1 -w '%{size_download}' --cacert "$ca" "${pin[@]}" "$listen/stations/42/live.mp3" || true) -gt 0 ]]; then
        on_air=$(now)
        break
    fi
    sleep 0.1
done
started=$(compose logs --no-log-prefix --timestamps playout 2>/dev/null |
    python3 -c '
import datetime, sys
for line in sys.stdin:
    stamp, _, message = line.partition(" ")
    if "station 42: started" in message:
        print(datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp())
        break
')
if [[ -n $on_air ]]; then
    [[ -n $started ]] && echo "info - autodj: library published to Liquidsoap started: $(elapsed "$enabled" "$started") s"
    [[ -n $started ]] && echo "info - autodj: Liquidsoap started to first byte on the mount: $(elapsed "$started" "$on_air") s"
    budget autodj_start "$(elapsed "$enabled" "$on_air")" "$LATENCY_MAX_AUTODJ_START"
else
    budget autodj_start "" "$LATENCY_MAX_AUTODJ_START"
fi
# The playout service restarts (a deploy, a crash) with its cache warm.
compose restart playout >/dev/null 2>&1
restarted=$(now)
back_on_air=
for _ in $(seq 1 300); do
    if [[ $(curl -sf -o /dev/null -m 1 -w '%{size_download}' --cacert "$ca" "${pin[@]}" "$listen/stations/42/live.mp3" || true) -gt 0 ]]; then
        back_on_air=$(now)
        break
    fi
    sleep 0.1
done
budget autodj_restart "$([[ -n $back_on_air ]] && elapsed "$restarted" "$back_on_air")" "$LATENCY_MAX_AUTODJ_RESTART"
# AutoDJ must be on both mounts before step 2.
for _ in $(seq 1 100); do
    [[ $(curl -sf -o /dev/null -m 1 -w '%{size_download}' --cacert "$ca" "${pin[@]}" "$listen/stations/42/live.opus" || true) -gt 0 ]] && break
    sleep 0.1
done

# --- 2. Live, AutoDJ, live ----------------------------------------------------

# A DJ on mount $1 for $2 seconds; latency_source.py writes the time of the
# first sample to $3. With $4, the source then sends nothing for $4 seconds
# but keeps its connection open. Encoder flags as the desktop app's
# (tc-station FfmpegExecutable.Arguments).
dj() {
    local mount=$1 seconds=$2 t0=$3 hang=${4:-0} rate content_type kbps codec
    if [[ $mount == *.mp3 ]]; then
        rate=44100 content_type=audio/mpeg kbps=128
        codec=(-c:a libmp3lame -b:a 128k -flush_packets 1 -write_xing 0 -f mp3)
    else
        rate=48000 content_type=audio/ogg kbps=64
        codec=(-c:a libopus -b:a 64k -application audio -flush_packets 1 -page_duration 100000 -f ogg)
    fi
    # Like the desktop app, no audio until Icecast accepts the source: $t0.pressed is when the DJ pressed Go Live,
    # $t0 when the first sample is captured (#93).
    rm -f "$t0.ready"
    { python3 tests/latency_source.py --seconds "$seconds" --rate "$rate" --t0 "$t0" --pressed "$t0.pressed" --wait-for "$t0.ready"
        sleep "$hang"; } |
        ffmpeg -nostdin -loglevel error -f s16le -ar "$rate" -ac 2 -probesize 32 -analyzeduration 0 -i pipe:0 \
            "${codec[@]}" pipe:1 |
        python3 tests/raw_source.py ingest.localhost "$https_port" "$mount" "42:$secret" --ca "$ca" \
            --connect 127.0.0.1 --content-type "$content_type" --bitrate "$kbps" --ready "$t0.ready" >/dev/null || true
}
# A listener on live.$2 for $3 seconds, recorded into $work/$1.
listener() {
    local name=$1 fmt=$2 seconds=$3
    curl -sN -m "$seconds" --cacert "$ca" "${pin[@]}" "$listen/stations/42/live.$fmt" |
        python3 tests/latency_listener.py "$work/$name" || true
}

for fmt in mp3 opus; do
    dj "/stations/42/live.$fmt" 35 "$work/$fmt.t0.1" &
    pids+=($!)
done
# Later than any burst Icecast had (8 s at 64 kbps before #85), so the
# listener gets a full one.
sleep 12
for fmt in mp3 opus; do
    listener "$fmt" "$fmt" 58 &
    pids+=($!)
done
sleep 33
for fmt in mp3 opus; do
    dj "/stations/42/live.$fmt" 15 "$work/$fmt.t0.2" &
    pids+=($!)
done
wait "${pids[@]}" 2>/dev/null || true
pids=()

summary=$work/summary.md
echo "| Delay (s) | MP3 128 kbps | Opus 64 kbps | Budget |" >"$summary"
echo "|---|---|---|---|" >>"$summary"
declare -A result
for fmt in mp3 opus; do
    result[$fmt]=$(python3 tests/latency.py "$work/$fmt" "$fmt" \
        --session "$(cat "$work/$fmt.t0.1"):35:$(cat "$work/$fmt.t0.1.pressed")" \
        --session "$(cat "$work/$fmt.t0.2"):15:$(cat "$work/$fmt.t0.2.pressed")") ||
        { echo "FAIL - $fmt: tests/latency.py failed, nothing measured"; result[$fmt]='{}'; }
    echo "info - $fmt: ${result[$fmt]}"
done
field() { python3 -c 'import json, sys; print(json.loads(sys.argv[1]).get(sys.argv[2]))' "${result[$1]}" "$2"; }
for fmt in mp3 opus; do
    check "$fmt: live, AutoDJ when the DJ stops, live when the DJ returns, AutoDJ again" "L A L A" "$(field "$fmt" timeline)"
    budget "$fmt first_audio" "$(field "$fmt" first_audio)" "$LATENCY_MAX_FIRST_AUDIO"
    budget "$fmt connect" "$(field "$fmt" connect)" "$LATENCY_MAX_DELAY"
    budget "$fmt steady" "$(field "$fmt" steady)" "$LATENCY_MAX_DELAY"
    budget "$fmt to_autodj" "$(field "$fmt" to_autodj)" "$LATENCY_MAX_TO_AUTODJ"
    budget "$fmt to_live" "$(field "$fmt" to_live)" "$LATENCY_MAX_SWITCH"
    budget "$fmt after_return" "$(field "$fmt" after_return)" "$LATENCY_MAX_AFTER_RETURN"
    measured["$fmt wire_steady"]=$(field "$fmt" wire_steady)
done

# --- 3. A DJ whose connection dies --------------------------------------------

for fmt in mp3 opus; do
    dj "/stations/42/live.$fmt" 10 "$work/dead-$fmt.t0" 15 &
    pids+=($!)
done
sleep 3
for fmt in mp3 opus; do
    listener "dead-$fmt" "$fmt" 17 &
    pids+=($!)
done
wait "${pids[@]}" 2>/dev/null || true
pids=()
for fmt in mp3 opus; do
    dead=$(python3 tests/latency.py "$work/dead-$fmt" "$fmt" --session "$(cat "$work/dead-$fmt.t0"):10")
    echo "info - $fmt, dead source: $dead"
    budget "$fmt dead_source" "$(python3 -c 'import json, sys; print(json.loads(sys.argv[1]).get("to_autodj"))' "$dead")" \
        "$LATENCY_MAX_DEAD_SOURCE"
done
row() { echo "| $1 | ${measured[mp3 $2]:-} | ${measured[opus $2]:-} | $3 |" >>"$summary"; }
row "Listener start to first audio" first_audio "$LATENCY_MAX_FIRST_AUDIO"
row "Microphone to ear, at connect" connect "$LATENCY_MAX_DELAY"
row "Microphone to ear, steady" steady "$LATENCY_MAX_DELAY"
row "Microphone to listener, on the wire" wire_steady "-"
row "Live to AutoDJ (DJ stops to AutoDJ heard)" to_autodj "$LATENCY_MAX_TO_AUTODJ"
row "AutoDJ to live (DJ starts to DJ heard)" to_live "$LATENCY_MAX_SWITCH"
row "Microphone to ear, after the DJ returns" after_return "$LATENCY_MAX_AFTER_RETURN"
row "DJ's connection dies to AutoDJ heard" dead_source "$LATENCY_MAX_DEAD_SOURCE"
echo "| AutoDJ warm-up (200 tracks published to first byte) | ${measured[autodj_start]:-} | | $LATENCY_MAX_AUTODJ_START |" >>"$summary"
echo "| AutoDJ restart, cache warm, to first byte | ${measured[autodj_restart]:-} | | $LATENCY_MAX_AUTODJ_RESTART |" >>"$summary"
cat "$summary"
[[ -n ${GITHUB_STEP_SUMMARY:-} ]] && { echo "### Latency (#84)"; cat "$summary"; } >>"$GITHUB_STEP_SUMMARY"

exit "$failures"
