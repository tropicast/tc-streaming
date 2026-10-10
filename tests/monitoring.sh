#!/usr/bin/env bash
# End-to-end check of node monitoring (#10): the exporter and Alloy push
# Icecast and host metrics to a local Prometheus (standing in for Grafana
# Cloud). Needs Docker with Compose, ffmpeg with libmp3lame, curl, python3.
set -euo pipefail

cd "$(dirname "$0")/.."
free_port() {
    python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}
run_id=${TEST_RUN_ID:-$$}
project=tcs-monitoring-$run_id
port=$(free_port)
prom_port=$(free_port)
env_file=$(mktemp)
trap '[[ -n ${KEEP:-} ]] || docker compose -p "$project" -f compose.yaml -f tests/monitoring.compose.yaml --env-file "$env_file" --profile monitoring down -v >/dev/null 2>&1; [[ -n ${KEEP:-} ]] || rm -f "$env_file"' EXIT

secret=$(openssl rand -hex 16)
cat >"$env_file" <<ENV
ICECAST_SOURCE_PASSWORD=$(openssl rand -hex 24)
ICECAST_ADMIN_PASSWORD=$(openssl rand -hex 24)
ICECAST_SOURCE_AUTH_USER=icecast
ICECAST_SOURCE_AUTH_PASSWORD=$(openssl rand -hex 24)
ICECAST_PORT=$port
STUB_STATIONS=42:$secret
LISTEN_HOST=listen.localhost
INGEST_HOST=ingest.localhost
ACME_EMAIL=dev@example.com
PROM_PORT=$prom_port
GRAFANA_CLOUD_PROM_URL=http://prometheus:9090/api/v1/write
GRAFANA_CLOUD_PROM_USER=test
GRAFANA_CLOUD_TOKEN=test
NODE_NAME=test-node
ENV

compose() {
    docker compose -p "$project" -f compose.yaml -f tests/monitoring.compose.yaml \
        --env-file "$env_file" --profile monitoring "$@"
}
build=(--build)
[[ -n ${E2E_PREBUILT:-} ]] && build=()
compose up -d "${build[@]}" --wait icecast auth-stub icecast-exporter prometheus >/dev/null
compose up -d alloy >/dev/null

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

# Value of a PromQL query, polled until it equals $2 or 90 s pass.
query_until() {
    local promql=$1 want=$2 got=""
    for _ in $(seq 1 45); do
        got=$(curl -s --get "http://127.0.0.1:$prom_port/api/v1/query" --data-urlencode "query=$promql" |
            python3 -c 'import sys, json; r = json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "none")')
        [[ $got == "$want" ]] && break
        sleep 2
    done
    echo "$got"
}

ffmpeg -nostdin -loglevel error -re -f lavfi -i sine -t 150 -c:a libmp3lame -b:a 64k \
    -content_type audio/mpeg -f mp3 "icecast://42:$secret@127.0.0.1:$port/stations/42/live.mp3" >/dev/null 2>&1 &
publisher=$!
sleep 3
curl -s -o /dev/null -m 140 "http://127.0.0.1:$port/stations/42/live.mp3" &
listener=$!

check "icecast_up is 1" 1 "$(query_until 'icecast_up{instance="test-node"}' 1)"
check "station 42 is live" 1 "$(query_until 'icecast_mount_up{station="42"}' 1)"
check "station 42 has 1 listener" 1 "$(query_until 'icecast_mount_listeners{station="42"}' 1)"
check "station 42 reports its bitrate (about 64 kbps)" 1 \
    "$(query_until '(icecast_mount_bitrate_kbps{station="42"} > bool 48) * (icecast_mount_bitrate_kbps{station="42"} < bool 80)' 1)"
check "host metrics arrive (up{job=node})" 1 "$(query_until 'up{job="node",instance="test-node"}' 1)"

kill "$listener" "$publisher" 2>/dev/null || true
compose stop icecast >/dev/null
check "icecast_up drops to 0 when Icecast stops" 0 "$(query_until 'icecast_up{instance="test-node"}' 0)"

exit "$failures"
