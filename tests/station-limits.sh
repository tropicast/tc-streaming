#!/usr/bin/env bash
# End-to-end check of per-station limits (#8): listener caps, the default
# cap, plan formats and bitrates, and a reload that keeps listeners.
# Needs Docker with Compose, ffmpeg with libmp3lame, curl and python3.
set -euo pipefail

cd "$(dirname "$0")/.."
free_port() {
    python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}
run_id=${TEST_RUN_ID:-$$}
project=tcs-limits-$run_id
port=$(free_port)
# Inside the repository: Docker Desktop only shares some host paths.
work=$(mktemp -d "$PWD/.tmp-limits.XXXXXX")
env_file=$work/env
stations=$work/stations.json
pids=()
# shellcheck disable=SC2317,SC2329 # called by the EXIT trap
cleanup() {
    kill "${pids[@]}" 2>/dev/null || true
    docker compose -p "$project" --env-file "$env_file" down -v >/dev/null 2>&1
    rm -rf "$work"
}
trap cleanup EXIT

secret42=$(openssl rand -hex 16)
secret77=$(openssl rand -hex 16)
write_limits() {
    # $1: station 42's listener cap. Overwrites in place for the bind mount.
    cat >"$stations" <<JSON
{"default": {"max_listeners": 3},
 "stations": {"42": {"plan": "free", "max_listeners": $1, "max_bitrate_kbps": 64, "formats": ["mp3"],
                     "directory": {"listed": true, "name": "Radio 42", "genre": "salegy", "country_code": "MG",
                                   "language_codes": "mg,fr", "homepage": "https://radio42.example",
                                   "logo": "https://radio42.example/logo.png",
                                   "main_stream_url": "https://listen.example/stations/42/live.mp3"}}}}
JSON
}
write_limits 2
cat >"$env_file" <<ENV
ICECAST_SOURCE_PASSWORD=$(openssl rand -hex 24)
ICECAST_ADMIN_PASSWORD=$(openssl rand -hex 24)
ICECAST_SOURCE_AUTH_USER=icecast
ICECAST_SOURCE_AUTH_PASSWORD=$(openssl rand -hex 24)
ICECAST_PORT=$port
STUB_STATIONS=42:$secret42,77:$secret77
STATIONS_JSON=$stations
LISTEN_HOST=listen.localhost
INGEST_HOST=ingest.localhost
ACME_EMAIL=dev@example.com
ENV

compose() { docker compose -p "$project" --env-file "$env_file" "$@"; }
build=(--build)
[[ -n ${E2E_PREBUILT:-} ]] && build=()
compose up -d "${build[@]}" --wait icecast auth-stub >/dev/null

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

tone() {
    ffmpeg -nostdin -loglevel error -re -f lavfi -i sine -t "$1" \
        -c:a libmp3lame -b:a 64k -f mp3 - 2>/dev/null
}
# Publish like a classic source; prints the first status code.
publish() {
    local credentials=$1 mount=$2 seconds=$3
    shift 3
    tone "$seconds" | python3 tests/raw_source.py 127.0.0.1 "$port" "$mount" "$credentials" --plain "$@" || true
}
# Start a listener in the background; its byte count lands in $work/$1.
listen() {
    curl -s -o "$work/$1" -m 120 "http://127.0.0.1:$port$2" &
    pids+=($!)
}
status() { curl -s -o /dev/null -m 3 -w '%{http_code}' "http://127.0.0.1:$port$1" || true; }
size() { stat -c %s "$work/$1" 2>/dev/null || echo 0; }

check "plan bitrate: 128 kbps declared on a 64 kbps plan is rejected" 401 \
    "$(publish "42:$secret42" /stations/42/live.mp3 2 --bitrate 128)"
check "plan format: opus mount outside the plan is rejected" 401 \
    "$(publish "42:$secret42" /stations/42/live.opus 2 --bitrate 64)"

publish "42:$secret42" /stations/42/live.mp3 100 --bitrate 64 >/dev/null &
pids+=($!)
publish "77:$secret77" /stations/77/live.mp3 100 >/dev/null &
pids+=($!)
sleep 3

listen a /stations/42/live.mp3
listen b /stations/42/live.mp3
sleep 2
check "station 42: listener above its cap of 2 is refused" 503 "$(status /stations/42/live.mp3)"

for name in c d e; do listen "$name" /stations/77/live.mp3; done
sleep 2
check "station 77 (no plan entry): default cap of 3 applies" 503 "$(status /stations/77/live.mp3)"

write_limits 4
compose exec -T icecast python3 /usr/local/bin/docker-entrypoint.py reload-stations >/dev/null
before_a=$(size a) before_b=$(size b)
sleep 4
check "reload keeps live listeners (a)" yes "$([[ $(size a) -gt $before_a ]] && echo yes || echo no)"
check "reload keeps live listeners (b)" yes "$([[ $(size b) -gt $before_b ]] && echo yes || echo no)"
listen f /stations/42/live.mp3
sleep 2
check "after reload, station 42 accepts a third listener" yes "$([[ $(size f) -gt 0 ]] && echo yes || echo no)"

# Directory metadata (tc-dashboard#13): headers a directory reads from the stream.
headers=$(curl -s -D - -o /dev/null -m 2 "http://127.0.0.1:$port/stations/42/live.mp3" | tr -d '\r' || true)
header() { grep -i "^$1:" <<<"$headers" | head -n 1 | cut -d' ' -f2-; }
check "listed station: icy-index-metadata" 1 "$(header icy-index-metadata)"
check "listed station: icy-name from the control plane" "Radio 42" "$(header icy-name)"
check "listed station: icy-genre" salegy "$(header icy-genre)"
check "listed station: icy-country-code" MG "$(header icy-country-code)"
check "listed station: icy-logo" https://radio42.example/logo.png "$(header icy-logo)"
check "unlisted station 77: no directory headers" "" "$(curl -s -D - -o /dev/null -m 2 "http://127.0.0.1:$port/stations/77/live.mp3" | tr -d '\r' | grep -i '^icy-index-metadata' || true)"

exit "$failures"
