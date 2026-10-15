#!/usr/bin/env bash
# End-to-end check of node monitoring (#10): the exporter and Alloy push
# Icecast and host metrics to a local Prometheus, and Icecast logs (#46) to a
# local Loki (both standing in for Grafana Cloud), and the AutoDJ metrics
# (#66) of the exporter and the playout service. Needs Docker with Compose,
# ffmpeg with libmp3lame, curl, python3.
set -euo pipefail

cd "$(dirname "$0")/.."
free_port() {
    python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}
run_id=${TEST_RUN_ID:-$$}
project=tcs-monitoring-$run_id
port=$(free_port)
prom_port=$(free_port)
loki_port=$(free_port)
# Inside the repository: Docker Desktop only shares some host paths.
work=$(mktemp -d "$PWD/.tmp-monitoring.XXXXXX")
env_file=$work/env
stub=$work/stub
compose() {
    docker compose -p "$project" -f compose.yaml -f tests/monitoring.compose.yaml -f tests/playout.compose.yaml \
        --env-file "$env_file" --profile monitoring --profile autodj "$@"
}
trap '[[ -n ${KEEP:-} ]] || compose down -v >/dev/null 2>&1; [[ -n ${KEEP:-} ]] || rm -rf "$work"' EXIT

secret=$(openssl rand -hex 16)

# AutoDJ for station 42 (#66): one track, served by the playout stub.
mkdir -p "$stub/tracks"
chmod 0755 "$work" "$stub" "$stub/tracks"
ffmpeg -nostdin -loglevel error -f lavfi -i "sine=frequency=440:duration=30" -c:a libmp3lame -b:a 64k "$stub/tracks/a.mp3"
python3 - "$stub" "$secret" <<'PY'
import hashlib, json, sys
from pathlib import Path
stub, secret = sys.argv[1:]
sha = hashlib.sha256(Path(stub, "tracks", "a.mp3").read_bytes()).hexdigest()
track = {"id": "a", "url": "http://playout-stub:9001/tracks/a.mp3", "sha256": sha}
output = {"format": "mp3", "bitrate_kbps": 64, "sample_rate": 44100, "channels": 2}
Path(stub, "state.json").write_text(json.dumps({"stations": {"42": {"password": secret, "outputs": [output], "tracks": [track]}}}))
PY
printf '%s\n' '{"stations": {"42": {"max_listeners": 10, "formats": ["mp3"], "autodj": true}}}' >"$work/stations.json"
chmod 0644 "$stub/tracks/a.mp3" "$stub/state.json" "$work/stations.json"

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
LOKI_PORT=$loki_port
GRAFANA_CLOUD_PROM_URL=http://prometheus:9090/api/v1/write
GRAFANA_CLOUD_PROM_USER=test
GRAFANA_CLOUD_LOKI_URL=http://loki:3100/loki/api/v1/push
GRAFANA_CLOUD_LOKI_USER=test
GRAFANA_CLOUD_TOKEN=test
NODE_NAME=test-node
STATIONS_JSON=$work/stations.json
PLAYOUT_URL=http://playout-stub:9001/playout
PLAYOUT_USER=playout
PLAYOUT_PASSWORD=$(openssl rand -hex 24)
PLAYOUT_POLL_SECONDS=2
PLAYOUT_STUB_DIR=$stub
ENV

build=(--build)
[[ -n ${E2E_PREBUILT:-} ]] && build=()
compose up -d "${build[@]}" --wait icecast auth-stub icecast-exporter prometheus loki playout-stub playout >/dev/null
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

# LogQL stream selector for this project's Icecast, plus extra matchers ($1).
icecast_logs() {
    printf '{job="icecast", instance="test-node", container=~"%s-icecast-.*"%s}' "$project" "${1:-}"
}

# Lines matching a LogQL query over the last 10 minutes.
logs_count() {
    curl -s --get "http://127.0.0.1:$loki_port/loki/api/v1/query" \
        --data-urlencode "query=sum(count_over_time($1 [10m]))" |
        python3 -c 'import sys, json; r = json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else 0)'
}

# Prints $2 once at least $2 lines match $1, else the last count after 90 s.
logs_until() {
    local got=0
    for _ in $(seq 1 45); do
        got=$(logs_count "$1")
        ((got >= $2)) && { echo "$2"; return; }
        sleep 2
    done
    echo "$got"
}

# Rejected first: the station's real source starts afterwards.
ffmpeg -nostdin -loglevel error -re -f lavfi -i sine -t 3 -c:a libmp3lame -b:a 64k \
    -content_type audio/mpeg -f mp3 "icecast://42:wrong-$secret@127.0.0.1:$port/stations/42/live.mp3" >/dev/null 2>&1 || true

ffmpeg -nostdin -loglevel error -re -f lavfi -i sine -t 150 -c:a libmp3lame -b:a 64k \
    -content_type audio/mpeg -f mp3 "icecast://42:$secret@127.0.0.1:$port/stations/42/live.mp3" >/dev/null 2>&1 &
publisher=$!
sleep 3
curl -s -o /dev/null -m 140 "http://127.0.0.1:$port/stations/42/live.mp3" &
listener=$!

check "icecast_up is 1" 1 "$(query_until 'icecast_up{instance="test-node"}' 1)"
# Local builds report the 0.0.0 placeholder; deploys set the release (#59).
check "the exporter reports the release" 1 "$(query_until 'tc_streaming_build_info{instance="test-node",version="0.0.0"}' 1)"
check "station 42 is live" 1 "$(query_until 'icecast_mount_up{station="42"}' 1)"
check "station 42 has 1 listener" 1 "$(query_until 'icecast_mount_listeners{station="42"}' 1)"
check "station 42 reports its bitrate (about 64 kbps)" 1 \
    "$(query_until '(icecast_mount_bitrate_kbps{station="42"} > bool 48) * (icecast_mount_bitrate_kbps{station="42"} < bool 80)' 1)"
check "host metrics arrive (up{job=node})" 1 "$(query_until 'up{job="node",instance="test-node"}' 1)"

# Logs (#46).
check "rejected source is in the error log" 1 \
    "$(logs_until "$(icecast_logs ', log_type="error"') |= \"wrong password\"" 1)"
check "rejected source is a 401 access line at level warn" 1 \
    "$(logs_until "$(icecast_logs ', log_type="access", level="warn"') | method=\"PUT\" | status=\"401\" | station=\"42\"" 1)"
check "Icecast startup is an error-log line at level info" 1 \
    "$(logs_until "$(icecast_logs ', log_type="error", level="info"') |= \"server started\" | module=\"main\"" 1)"

# Secrets are redacted before they leave the node. Icecast strips query
# strings itself, so write such lines to its stdout directly (it is PID 1).
leak=leak-$(openssl rand -hex 8)
compose exec -T icecast sh -c "printf '%s\\n' \
    '[2026-01-01  00:00:00] WARN test/redact url http://u:$leak@h/x?pass=$leak&mount=/a' \
    '[2026-01-01  00:00:00] WARN test/redact empty user, slash icecast://:$leak/x@h/ src://s:ab/$leak@h/' \
    '[2026-01-01  00:00:00] WARN test/redact prefixed access_token=$leak api_key=$leak client_secret=$leak ICECAST_ADMIN_PASSWORD=$leak' \
    '[2026-01-01  00:00:00] WARN test/redact json {\"password\": \"$leak\", \"x-auth-token\":\"$leak\"}' \
    '[2026-01-01  00:00:00] WARN test/redact xml <source-password>$leak</source-password>' \
    '[2026-01-01  00:00:00] WARN test/redact basic Authorization: Basic $leak' \
    '[2026-01-01  00:00:00] WARN test/redact digest Authorization: Digest username=\"admin\", response=\"$leak\"' \
    '[2026-01-01  00:00:00] WARN test/redact token Authorization: Token $leak' >/proc/1/fd/1"
check "redaction test lines arrive" 8 "$(logs_until "$(icecast_logs) |= \"test/redact\"" 8)"
check "no secret reaches Loki" 0 "$(logs_count "$(icecast_logs) |= \"$leak\"")"
# Several healthchecks and exporter scrapes ran by now.
check "healthcheck and exporter polling are not shipped" 0 \
    "$(logs_count "$(icecast_logs) |~ \"status-json|admin/stats\"")"

# Alloy reaches Docker only through the proxy, and the proxy only lets
# through the GET calls log collection needs.
check "Alloy cannot see the host's docker.sock" no \
    "$(compose exec -T alloy sh -c 'test -e /host/root/run/docker.sock || test -e /host/root/var/run/docker.sock && echo yes || echo no')"
icecast_id=$(compose ps -q icecast)
proxy() {  # proxy <method> <path>: HTTP status through docker-socket-proxy, as Alloy
    docker run --rm --network "container:$(compose ps -q alloy)" curlimages/curl:8.23.0 \
        -s -o /dev/null -w '%{http_code}' -X "$1" "http://docker-socket-proxy:2375$2"
}
check "proxy allows container logs" 200 "$(proxy GET "/v1.43/containers/$icecast_id/logs?stdout=1&tail=1")"
check "proxy refuses reading container files" 403 "$(proxy GET "/v1.43/containers/$icecast_id/archive?path=/etc/passwd")"
check "proxy refuses exec" 405 "$(proxy POST "/v1.43/containers/$icecast_id/exec")"

# AutoDJ (#66): the exporter's AutoDJ metrics and the playout service's own.
check "station 42 has AutoDJ" 1 "$(query_until 'tc_station_autodj_enabled{instance="test-node",station="42"}' 1)"
check "station 42's AutoDJ mount has a source" 1 "$(query_until 'tc_autodj_mount_up{instance="test-node",station="42",format="mp3"}' 1)"
check "AutoDJ mounts stay out of the station-keyed series" 1 \
    "$(query_until 'count(icecast_mount_up{instance="test-node",station="42"})' 1)"
check "playout is scraped" 1 "$(query_until 'up{job="playout",instance="test-node"}' 1)"
check "playout runs station 42" 1 "$(query_until 'playout_station_running{instance="test-node",station="42"}' 1)"
check "playout reads the control plane" 1 "$(query_until 'playout_endpoint_up{instance="test-node"}' 1)"
# The alert expressions, without their "for" (the local Prometheus runs no rules).
check "StationOffAir does not match while live and AutoDJ are up" none \
    "$(query_until 'tc_station_autodj_enabled unless on (instance, station) (tc_autodj_mount_up or icecast_mount_up{station!=""})' none)"
compose stop playout >/dev/null
check "PlayoutDown matches once playout stops" 0 \
    "$(query_until 'up{job="playout"} == 0 and on (instance) (count by (instance) (tc_station_autodj_enabled) > 0)' 0)"
check "AutoDJSourceMissing matches once playout stops" 1 \
    "$(query_until 'tc_station_autodj_enabled unless on (instance, station) tc_autodj_mount_up unless on (instance) icecast_up == 0' 1)"

kill "$listener" "$publisher" 2>/dev/null || true
check "listener disconnect is an access line" 1 \
    "$(logs_until "$(icecast_logs ', log_type="access", level="info"') | method=\"GET\" | mount=\"/stations/42/live.mp3\"" 1)"

# A recreated container (new image on deploy) is picked up; earlier lines stay.
compose up -d --force-recreate --wait icecast >/dev/null
check "logs of the recreated container arrive" 2 "$(logs_until "$(icecast_logs) |= \"server started\"" 2)"
check "logs from before the recreate are kept" 1 "$(logs_until "$(icecast_logs) |= \"wrong password\"" 1)"

compose stop icecast >/dev/null
check "icecast_up drops to 0 when Icecast stops" 0 "$(query_until 'icecast_up{instance="test-node"}' 0)"

exit "$failures"
