#!/usr/bin/env bash
# End-to-end check of per-station limits (#8): listener caps, the default
# cap, plan formats and bitrates, a reload that keeps listeners, caps
# Icecast cannot take (#55), and AutoDJ fallback mounts (#62).
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
secret99=$(openssl rand -hex 16)
secret55=$(openssl rand -hex 16)
write_limits() {
    # $1: station 42's listener cap; $2: station 55's AutoDJ flag (default
    # true). Overwrites in place for the bind mount.
    cat >"$stations" <<JSON
{"default": {"max_listeners": 3},
 "stations": {"42": {"plan": "free", "max_listeners": $1, "max_bitrate_kbps": 64, "formats": ["mp3"],
                     "directory": {"listed": true, "name": "Radio 42", "genre": "salegy", "country_code": "MG",
                                   "language_codes": "mg,fr", "homepage": "https://radio42.example",
                                   "logo": "https://radio42.example/logo.png",
                                   "main_stream_url": "https://listen.example/stations/42/live.mp3"}},
              "99": {"plan": "starter", "max_listeners": 10, "formats": ["mp3"], "directory": {"listed": false}},
              "55": {"plan": "pro", "max_listeners": 25000, "formats": ["mp3", "opus"], "autodj": ${2:-true}}}}
JSON
}
write_limits 2
cat >"$env_file" <<ENV
ICECAST_SOURCE_PASSWORD=$(openssl rand -hex 24)
ICECAST_ADMIN_PASSWORD=$(openssl rand -hex 24)
ICECAST_SOURCE_AUTH_USER=icecast
ICECAST_SOURCE_AUTH_PASSWORD=$(openssl rand -hex 24)
ICECAST_PORT=$port
STUB_STATIONS=42:$secret42,77:$secret77,99:$secret99,55:$secret55
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

# Delisted station 99 (listed false), with room under its cap: only the opt-out.
publish "99:$secret99" /stations/99/live.mp3 30 >/dev/null &
pids+=($!)
sleep 3
delisted=$(curl -s -D - -o /dev/null -m 2 "http://127.0.0.1:$port/stations/99/live.mp3" | tr -d '\r' || true)
check "delisted station: answers (not at its cap)" 200 "$(head -n 1 <<<"$delisted" | cut -d' ' -f2)"
check "delisted station: icy-do-not-index" 1 "$(grep -i '^icy-do-not-index:' <<<"$delisted" | cut -d' ' -f2-)"
check "delisted station: no listed-only headers" "" "$(grep -iE '^icy-(country-code|logo|language-codes|main-stream-url):' <<<"$delisted" || true)"

# Caps Icecast cannot take (#55): above its 16384 limit the cap is lowered,
# 0 is refused before Icecast sees it and the running config is kept.
config_cap() {
    compose exec -T icecast python3 -c 'import sys, xml.etree.ElementTree as ET
r = ET.parse("/run/icecast/icecast.xml").getroot()
print(" ".join(m.findtext("max-listeners") for m in r.findall("mount") if m.findtext("mount-name") == sys.argv[1]))' "$1"
}
check "Pro cap of 25000 is lowered to 16384 (mp3)" 16384 "$(config_cap /stations/55/live.mp3)"
check "Pro cap of 25000 is lowered to 16384 (opus)" 16384 "$(config_cap /stations/55/live.opus)"

# AutoDJ (#62): station 55 has a hidden autodj.<fmt> mount per format, and
# its live mounts fall back to them.
mount_setting() {
    compose exec -T icecast python3 -c 'import sys, xml.etree.ElementTree as ET
r = ET.parse("/run/icecast/icecast.xml").getroot()
print(" ".join(m.findtext(sys.argv[2]) or "-" for m in r.findall("mount") if m.findtext("mount-name") == sys.argv[1]))' "$1" "$2"
}
check "AutoDJ: live mp3 falls back to autodj.mp3" /stations/55/autodj.mp3 "$(mount_setting /stations/55/live.mp3 fallback-mount)"
check "AutoDJ: live opus falls back to autodj.opus" /stations/55/autodj.opus "$(mount_setting /stations/55/live.opus fallback-mount)"
check "AutoDJ: listeners return to live" all "$(mount_setting /stations/55/live.mp3 fallback-override)"
check "AutoDJ: autodj mount is hidden" 1 "$(mount_setting /stations/55/autodj.mp3 hidden)"
check "AutoDJ: autodj mount has the live cap" 16384 "$(mount_setting /stations/55/autodj.opus max-listeners)"
check "AutoDJ: no fallback for stations without it" - "$(mount_setting /stations/42/live.mp3 fallback-mount)"
check "Icecast takes the fallback settings without warnings" 0 \
    "$(compose logs icecast | grep -c 'Old style fallback override' || true)"

publish "55:$secret55" /stations/55/autodj.mp3 100 >/dev/null &
pids+=($!)
sleep 3
listen g /stations/55/live.mp3
sleep 3
check "AutoDJ: a listener on the idle live mount hears AutoDJ" yes "$([[ $(size g) -gt 0 ]] && echo yes || echo no)"
check "AutoDJ: autodj mount is not on the public status page" 0 \
    "$(curl -s -m 3 "http://127.0.0.1:$port/status-json.xsl" | grep -c 'autodj' || true)"

write_limits 4 false
compose exec -T icecast python3 /usr/local/bin/docker-entrypoint.py reload-stations >/dev/null
check "AutoDJ off: reload removes the fallback" - "$(mount_setting /stations/55/live.mp3 fallback-mount)"
check "AutoDJ off: reload removes the autodj mounts" "" "$(mount_setting /stations/55/autodj.mp3 hidden)"
check "Icecast accepts every generated cap" 0 "$(compose logs icecast | grep -c 'out of range' || true)"
write_limits 0
reload_error=$(compose exec -T icecast python3 /usr/local/bin/docker-entrypoint.py reload-stations 2>&1 >/dev/null || true)
check "a cap of 0 fails the reload with a clear message" yes \
    "$([[ $reload_error == *"station 42 needs an integer max_listeners >= 1"* ]] && echo yes || echo no)"
check "a failed reload keeps the running caps" 4 "$(config_cap /stations/42/live.mp3)"

exit "$failures"
