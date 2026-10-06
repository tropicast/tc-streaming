#!/usr/bin/env bash
# End-to-end check of station-scoped source auth (#7) against the local stub.
# Needs Docker with Compose and ffmpeg with libmp3lame.
set -euo pipefail

cd "$(dirname "$0")/.."
port=${TEST_PORT:-18000}
project=tcs-source-auth-test
env_file=$(mktemp)
trap 'docker compose -p "$project" --env-file "$env_file" down -v >/dev/null 2>&1; rm -f "$env_file"' EXIT

secret42=$(openssl rand -hex 16)
secret77=$(openssl rand -hex 16)
global=$(openssl rand -hex 24)
cat >"$env_file" <<ENV
ICECAST_SOURCE_PASSWORD=$global
ICECAST_ADMIN_PASSWORD=$(openssl rand -hex 24)
ICECAST_SOURCE_AUTH_USER=icecast
ICECAST_SOURCE_AUTH_PASSWORD=$(openssl rand -hex 24)
ICECAST_PORT=$port
STUB_STATIONS=42:$secret42,77:$secret77
LISTEN_HOST=listen.localhost
INGEST_HOST=ingest.localhost
ACME_EMAIL=dev@example.com
ENV

compose() { docker compose -p "$project" --env-file "$env_file" "$@"; }
# Icecast and the stub only; the gateway has its own test.
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

# Publish a short tone; prints "ok" or "denied".
publish() {
    local credentials=$1 mount=$2 seconds=${3:-2}
    if ffmpeg -nostdin -loglevel error -re -f lavfi -i sine -t "$seconds" \
        -c:a libmp3lame -b:a 64k -content_type audio/mpeg -f mp3 \
        "icecast://$credentials@127.0.0.1:$port$mount" >/dev/null 2>&1; then
        echo ok
    else
        echo denied
    fi
}

check "station publishes to its own mount" ok "$(publish "42:$secret42" /stations/42/live.mp3)"
check "wrong password is rejected" denied "$(publish "42:wrong" /stations/42/live.mp3)"
check "station cannot publish to another station" denied "$(publish "42:$secret42" /stations/77/live.mp3)"
check "global source password is rejected" denied "$(publish "source:$global" /stations/42/live.mp3)"
check "mount outside the layout is rejected" denied "$(publish "42:$secret42" /other.mp3)"

publish "77:$secret77" /stations/77/live.mp3 8 >/dev/null &
live_pid=$!
sleep 3
bytes=$(curl -s -m 2 -o /dev/null -w '%{size_download}' "http://127.0.0.1:$port/stations/77/live.mp3" || true)
check "listener receives audio from a live mount" yes "$([[ ${bytes:-0} -gt 0 ]] && echo yes || echo no)"
check "second source on a live mount is rejected" denied "$(publish "77:$secret77" /stations/77/live.mp3)"
wait "$live_pid" || true

compose stop auth-stub >/dev/null
check "auth endpoint down denies the source" denied "$(publish "42:$secret42" /stations/42/live.mp3)"

if compose logs icecast | grep -qF -e "$secret42" -e "$global"; then
    check "logs contain no source passwords" clean leaked
else
    check "logs contain no source passwords" clean clean
fi

exit "$failures"
