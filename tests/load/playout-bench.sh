#!/usr/bin/env bash
# CPU and memory of the AutoDJ playout service per station (#65).
# Runs Icecast, the auth and playout stubs and the playout image with N
# AutoDJ stations, each publishing MP3 128 kbps (44.1 kHz stereo) and Ogg
# Opus 64 kbps (48 kHz stereo) from pink-noise tracks, so the encoders work
# as hard as with music. After a warm-up, samples `docker stats` every
# 5 seconds and prints one CSV line per station count:
#   stations,playout_cpu_pct,playout_mem_mb,icecast_cpu_pct,sources
# 100% CPU = one core. Run on the node type you plan for (tc-runner-1 is the
# same Hetzner type as tc-stream-1):
#   tests/load/playout-bench.sh 1 5 10 20
# Needs Docker with Compose, ffmpeg with libmp3lame, curl and python3.
set -euo pipefail

cd "$(dirname "$0")/../.."
counts=("${@:-1 5 10}")
read -r -a counts <<<"${counts[*]}"
free_port() {
    python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}
project=tcs-bench-${TEST_RUN_ID:-$$}
port=$(free_port)
warmup=${WARMUP:-20}
samples=${SAMPLES:-12}
work=$(mktemp -d "$PWD/.tmp-bench.XXXXXX")
stub=$work/stub
env_file=$work/env
# shellcheck disable=SC2317,SC2329 # called by the EXIT trap
cleanup() {
    compose down -v >/dev/null 2>&1
    rm -rf "$work"
}
trap cleanup EXIT
mkdir -p "$stub/tracks"
chmod 0755 "$work" "$stub" "$stub/tracks"

secret=$(openssl rand -hex 16)
admin_password=$(openssl rand -hex 24)
max=0
for n in "${counts[@]}"; do ((n > max)) && max=$n; done

# Three pink-noise tracks, so the playlist moves on during a sample.
for i in 1 2 3; do
    ffmpeg -nostdin -loglevel error -f lavfi -i "anoisesrc=color=pink:duration=90:seed=$i" -ac 2 \
        -c:a libmp3lame -b:a 192k "$stub/tracks/p$i.mp3"
done
chmod 0644 "$stub/tracks"/*

# $1: the number of stations to play.
write_state() {
    python3 - "$stub" "$secret" "$1" <<'PY'
import hashlib, json, sys
from pathlib import Path
stub, secret, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
tracks = []
for i in (1, 2, 3):
    path = Path(stub, "tracks", f"p{i}.mp3")
    tracks.append({"id": f"p{i}", "url": f"http://playout-stub:9001/tracks/p{i}.mp3",
                   "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
outputs = [{"format": "mp3", "bitrate_kbps": 128, "sample_rate": 44100, "channels": 2},
           {"format": "opus", "bitrate_kbps": 64, "sample_rate": 48000, "channels": 2}]
state = {"stations": {f"b{i}": {"password": secret, "shuffle": True, "outputs": outputs, "tracks": tracks}
                      for i in range(1, n + 1)}}
Path(stub, "state.json").write_text(json.dumps(state))
PY
    chmod 0644 "$stub/state.json"
}
write_state 0

python3 - "$work/stations.json" "$max" <<'PY'
import json, sys
path, n = sys.argv[1], int(sys.argv[2])
stations = {f"b{i}": {"max_listeners": 10, "formats": ["mp3", "opus"], "autodj": True} for i in range(1, n + 1)}
json.dump({"default": {"max_listeners": 10}, "stations": stations}, open(path, "w"))
PY
chmod 0644 "$work/stations.json"
stub_stations=$(for i in $(seq 1 "$max"); do printf 'b%s:%s,' "$i" "$secret"; done)

cat >"$env_file" <<ENV
ICECAST_SOURCE_PASSWORD=$(openssl rand -hex 24)
ICECAST_ADMIN_PASSWORD=$admin_password
ICECAST_SOURCE_AUTH_USER=icecast
ICECAST_SOURCE_AUTH_PASSWORD=$(openssl rand -hex 24)
ICECAST_PORT=$port
STUB_STATIONS=${stub_stations%,}
STATIONS_JSON=$work/stations.json
LISTEN_HOST=listen.localhost
INGEST_HOST=ingest.localhost
ACME_EMAIL=dev@example.com
COMPOSE_PROFILES=autodj
PLAYOUT_URL=http://playout-stub:9001/playout
PLAYOUT_USER=playout
PLAYOUT_PASSWORD=$(openssl rand -hex 24)
PLAYOUT_POLL_SECONDS=2
PLAYOUT_STUB_DIR=$stub
# Measure the real cost: no CPU or memory limit (0 = unlimited).
PLAYOUT_CPUS=${PLAYOUT_CPUS:-0}
PLAYOUT_MEMORY=${PLAYOUT_MEMORY:-0}
ENV

compose() { docker compose -p "$project" --env-file "$env_file" -f compose.yaml -f tests/playout.compose.yaml "$@"; }
build=(--build)
[[ -n ${E2E_PREBUILT:-} ]] && build=()
compose up -d "${build[@]}" --wait icecast auth-stub playout-stub playout >/dev/null
playout=$(compose ps -q playout)
icecast=$(compose ps -q icecast)

sources() {
    # listmounts is one line: count the matches, not the lines.
    curl -s -m 3 -u "admin:$admin_password" "http://127.0.0.1:$port/admin/listmounts" |
        grep -o 'mount="/stations/b[0-9]*/autodj' | wc -l
}
# CPU % and memory MiB of container $1 from one `docker stats` sample.
stats() {
    docker stats --no-stream --format '{{.CPUPerc}} {{.MemUsage}}' "$1" |
        awk '{ cpu = $1; sub("%", "", cpu); mem = $2; unit = mem; gsub(/[0-9.]/, "", unit); sub(/[A-Za-z]+$/, "", mem)
               if (unit == "GiB") mem *= 1024; else if (unit == "KiB") mem /= 1024; printf "%s %.1f\n", cpu, mem }'
}

echo "stations,playout_cpu_pct,playout_mem_mb,icecast_cpu_pct,sources"
for n in "${counts[@]}"; do
    write_state "$n"
    for _ in $(seq 1 90); do
        [[ $(sources) -ge $((n * 2)) ]] && break
        sleep 1
    done
    sleep "$warmup"
    cpu_sum=0 mem_max=0 ice_sum=0
    for _ in $(seq 1 "$samples"); do
        read -r cpu mem < <(stats "$playout")
        read -r ice _ < <(stats "$icecast")
        cpu_sum=$(awk -v a="$cpu_sum" -v b="$cpu" 'BEGIN { print a + b }')
        ice_sum=$(awk -v a="$ice_sum" -v b="$ice" 'BEGIN { print a + b }')
        mem_max=$(awk -v a="$mem_max" -v b="$mem" 'BEGIN { print (b > a ? b : a) }')
        sleep 5
    done
    awk -v n="$n" -v c="$cpu_sum" -v m="$mem_max" -v i="$ice_sum" -v k="$samples" -v s="$(sources)" \
        'BEGIN { printf "%d,%.1f,%.0f,%.1f,%d\n", n, c / k, m, i / k, s }'
done
