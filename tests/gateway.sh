#!/usr/bin/env bash
# End-to-end check of the Caddy TLS gateway (#6) with Caddy's local CA.
# Needs Docker with Compose, ffmpeg with libmp3lame, curl and python3.
# Publishes with tests/raw_source.py (a classic Icecast source: PUT or SOURCE
# with no length) and with curl (chunked). FFmpeg's icecast:// output would
# be the real thing, but it ignores -ca_file so it cannot trust the local CA.
set -euo pipefail

cd "$(dirname "$0")/.."
# Parallel-safe on a shared Docker host: a unique Compose project per run
# and free host ports unless TEST_* ports are given.
free_port() {
    python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}
run_id=${TEST_RUN_ID:-$$}
https_port=${TEST_HTTPS_PORT:-$(free_port)}
http_port=${TEST_HTTP_PORT:-$(free_port)}
project=tcs-gateway-$run_id
work=$(mktemp -d)
env_file=$work/env
ca=$work/root.crt
trap '[[ -n ${KEEP:-} ]] || docker compose -p "$project" --env-file "$env_file" down -v >/dev/null 2>&1; rm -rf "$work"' EXIT

secret=$(openssl rand -hex 16)
cat >"$env_file" <<ENV
ICECAST_SOURCE_PASSWORD=$(openssl rand -hex 24)
ICECAST_ADMIN_PASSWORD=$(openssl rand -hex 24)
ICECAST_SOURCE_AUTH_USER=icecast
ICECAST_SOURCE_AUTH_PASSWORD=$(openssl rand -hex 24)
ICECAST_PORT=${TEST_ICECAST_PORT:-$(free_port)}
STUB_STATIONS=42:$secret
LISTEN_HOST=listen.localhost
INGEST_HOST=ingest.localhost
ACME_EMAIL=dev@example.com
CADDY_GLOBAL_OPTIONS=local_certs
CADDY_HTTP_PORT=$http_port
CADDY_HTTPS_PORT=$https_port
ENV

compose() { docker compose -p "$project" --env-file "$env_file" "$@"; }
# CI builds the images once (E2E_PREBUILT=1); locally Compose builds them.
build=(--build)
[[ -n ${E2E_PREBUILT:-} ]] && build=()
compose up -d "${build[@]}" --wait >/dev/null

for _ in $(seq 1 30); do
    compose cp caddy:/data/caddy/pki/authorities/local/root.crt "$ca" >/dev/null 2>&1 && break
    sleep 1
done

# *.localhost may resolve to ::1 while Docker publishes on 127.0.0.1.
pin=(--resolve "listen.localhost:$https_port:127.0.0.1" --resolve "ingest.localhost:$https_port:127.0.0.1"
     --resolve "listen.localhost:$http_port:127.0.0.1")
listen=https://listen.localhost:$https_port
ingest=https://ingest.localhost:$https_port

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
status() { curl -s -o /dev/null -w '%{http_code}' --cacert "$ca" "${pin[@]}" "$@" || true; }

tone() {
    timeout "$1" ffmpeg -nostdin -loglevel error -re -f lavfi -i sine \
        -c:a libmp3lame -b:a 64k -f mp3 - 2>/dev/null
}

# Classic Icecast source: $1 credentials, $2 seconds, $3 method, $4 mount.
publish() {
    tone "$2" | python3 tests/raw_source.py ingest.localhost "$https_port" \
        "${4:-/stations/42/live.mp3}" "$1" --method "${3:-PUT}" --ca "$ca" \
        --connect 127.0.0.1 || true
}

# Chunked HTTP upload, as curl or FFmpeg's https:// output send it.
publish_chunked() {
    tone "$2" | curl -s -o /dev/null -w '%{http_code}' --cacert "$ca" "${pin[@]}" \
        -u "$1" -T - -H 'Content-Type: audio/mpeg' -H 'Expect:' \
        "$ingest/stations/42/live.mp3" || true
}

# Bytes a listener receives in 5 seconds.
listen_bytes() {
    curl -s -o /dev/null -m 5 --cacert "$ca" "${pin[@]}" -w '%{size_download}' \
        "$listen/stations/42/live.mp3" || true
}

check "admin pages are hidden" 404 "$(status "$listen/admin/stats.xml")"
check "status pages are hidden" 404 "$(status "$listen/status-json.xsl")"
check "listen host refuses PUT" 404 "$(status -X PUT "$listen/stations/42/live.mp3")"
check "ingest host closes GET" 000 "$(status "$ingest/stations/42/live.mp3")"
check "ingest host closes admin requests" closed "$(publish "42:$secret" 2 PUT /admin/stats.xml)"
check "HTTP redirects to HTTPS" 308 "$(status "http://listen.localhost:$http_port/stations/42/live.mp3")"
check "CORS preflight succeeds" 204 "$(status -X OPTIONS "$listen/stations/42/live.mp3")"
check "wrong credential is rejected" 401 "$(publish 42:wrong 3)"

for method in PUT SOURCE; do
    publish "42:$secret" 8 "$method" >/dev/null &
    sleep 3
    bytes=$(listen_bytes)
    check "classic $method source reaches listeners (>= 30 KB in 5 s)" yes \
        "$([[ ${bytes:-0} -ge 30000 ]] && echo yes || echo no)"
    wait
done

# Opus (#9): an Ogg Opus source on the .opus mount reaches listeners as
# audio/ogg and decodes as Opus.
opus_tone() {
    timeout "$1" ffmpeg -nostdin -loglevel error -re -f lavfi -i sine -ac 2 \
        -c:a libopus -b:a 64k -f ogg - 2>/dev/null
}
opus_tone 10 | python3 tests/raw_source.py ingest.localhost "$https_port" \
    /stations/42/live.opus "42:$secret" --ca "$ca" --connect 127.0.0.1 \
    --content-type audio/ogg --bitrate 64 >/dev/null || true &
sleep 3
curl -s -D "$work/opus.headers" -o "$work/opus.ogg" -m 5 --cacert "$ca" "${pin[@]}" \
    "$listen/stations/42/live.opus" || true
check "Opus mount is served as audio/ogg" yes \
    "$(grep -qi '^content-type: audio/ogg' "$work/opus.headers" && echo yes || echo no)"
check "Opus stream decodes as opus" opus \
    "$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$work/opus.ogg" 2>/dev/null || echo none)"
wait

publish_chunked "42:$secret" 8 >/dev/null &
sleep 3
bytes=$(listen_bytes)
check "chunked upload reaches listeners (>= 30 KB in 5 s)" yes \
    "$([[ ${bytes:-0} -ge 30000 ]] && echo yes || echo no)"
wait

publish "42:$secret" 15 >/dev/null &
sleep 4
read -r code type bytes < <(curl -s -o /dev/null -m 5 --cacert "$ca" "${pin[@]}" \
    -w '%{http_code} %{content_type} %{size_download}\n' "$listen/stations/42/live.mp3" || true)
check "listener gets the stream over HTTPS" "200 audio/mpeg" "$code $type"
check "audio keeps flowing (>= 30 KB in 5 s)" yes "$([[ ${bytes:-0} -ge 30000 ]] && echo yes || echo no)"
headers=$(curl -s -D - -o /dev/null -m 2 --cacert "$ca" "${pin[@]}" "$listen/stations/42/live.mp3" || true)
check "CORS header is set" yes "$(grep -qi '^access-control-allow-origin: \*' <<<"$headers" && echo yes || echo no)"
check "HSTS header is set" yes "$(grep -qi '^strict-transport-security:' <<<"$headers" && echo yes || echo no)"
wait

basic=$(printf '42:%s' "$secret" | base64)
if compose logs caddy | grep -qF -e "$secret" -e "$basic"; then
    check "gateway logs contain no credentials" clean leaked
else
    check "gateway logs contain no credentials" clean clean
fi

exit "$failures"
