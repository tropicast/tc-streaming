# Icecast

`Dockerfile` builds Icecast 2.5.0 and libigloo 0.9.5 from official source
archives with pinned SHA-256 checksums. The runtime stage runs Icecast as a
non-root user. `docker-entrypoint.py` writes the passwords from the
environment into a private copy of `icecast.xml`, then removes them from the
environment before starting Icecast.

## Run locally

```sh
cp .env.example .env
# Fill in .env, e.g. with: openssl rand -hex 24
docker compose up -d --build --wait
curl --fail http://127.0.0.1:8000/status-json.xsl
```

Compose publishes Icecast on localhost only. Set `ICECAST_PORT` in `.env` to
use another host port. `ICECAST_RELAY_PASSWORD` is optional; a random one is
generated at startup when it is unset.

Keep `.env` private. See [Source authentication](#source-authentication) to
publish a test tone.

## Production configuration

`icecast.xml` is the production config for one shared multi-tenant node
(issue #5):

- Each station gets the mounts `/stations/{station-id}/live.mp3` and
  `/stations/{station-id}/live.opus`.
- Limits are sized for a CX33 and its 20 TB monthly egress quota: 1500
  clients and 50 live sources. The load test (#12,
  [docs/load-test.md](../load-test.md)) ran 1,400 listeners with no drops
  at under 15% CPU; the monthly quota, not the CPU, is the limit.
- Icecast is never exposed directly. Caddy is the only public entry point
  and the firewall keeps port 8000 closed.
- Static file serving is off. The root page returns 404, while
  `/status-json.xsl` still works for the healthcheck.
- Logs go to stdout. The access log records the source username, never the
  password. With monitoring on, Alloy ships them to Grafana Cloud Logs.
- `ICECAST_HOSTNAME` sets the public hostname Icecast reports.
- The global source password is an internal break-glass secret only.
- The relay password is generated per node unless `ICECAST_RELAY_PASSWORD`
  is set.
- Compose raises the container's open-file limit to 65536, because each
  listener holds one file descriptor.

## Station limits

Each station gets its own Icecast mounts with a listener cap (issue #8).
`stations.json` holds the desired state, from the control plane:

```json
{
  "default": { "max_listeners": 100 },
  "stations": {
    "42": {
      "plan": "free",
      "max_listeners": 100,
      "max_bitrate_kbps": 64,
      "formats": ["mp3", "opus"]
    }
  }
}
```

- `max_listeners`: a listener above the cap gets `503`. Stations without an
  entry use `default.max_listeners` (the free-tier cap). It must be an
  integer of at least 1. Icecast accepts at most 16384, so higher caps (the
  Pro plan's 25,000) are lowered to 16384; a node serves far fewer listeners
  anyway (`<clients>`).
- `formats` and `max_bitrate_kbps` are checked by the source auth endpoint
  when a station connects, using the bitrate the source declares
  (`Ice-Bitrate` / `Ice-Audio-Info`). See [`docs/source-auth.md`](../source-auth.md).
- The entrypoint renders one `<mount>` per station and format, with a copy
  of the source authentication. `docker-entrypoint.py reload-stations`
  re-renders them and reloads Icecast with `SIGHUP`: live listeners and
  sources stay connected.
- Burst (#85): each station mount, AutoDJ mounts included, gets a
  `<burst-size>` of 0.5 s at its `max_bitrate_kbps` (Opus counted at no more
  than 96 kbps), at least 4 KiB: 4 KiB at 64 kbps, 8,000 bytes at 128 kbps,
  20,000 at 320 kbps. Mounts of a station without a cap use the global 8 KiB.
  A listener gets the burst at connect, then stays that far behind the
  source; a client moved by `fallback-mount` or `fallback-override` keeps
  its place, so a switch adds no backlog of its own
  ([Latency](latency.md)). A player that buffers before it plays (VLC, most
  apps) now waits that long at start instead of filling up from the burst.
- `<source-timeout>` is 3 s: a DJ whose connection dies without closing
  hands over to AutoDJ about 3 s later, and the desktop app reconnects.
- `directory` (optional, tc-dashboard#13): public metadata of a station
  listed in directories such as RadioBrowser: `listed`, `name`,
  `description`, `genre`, `homepage`, `logo`, `country_code`,
  `language_codes`, `main_stream_url`, `geo_lat_long` (`"<lat>,<long>"` in
  decimal degrees, #105, sent as `icy-geo-lat-long`). When listed, the station's mounts (its AutoDJ
  mounts too, #107: a listener on an idle live mount gets their headers) send
  `icy-version: 2`, `icy-index-metadata: 1` and the matching `icy-*` headers,
  which directories read to update their listing (RadioBrowser has no edit
  API). These headers come before any the source sends, so the control
  plane's values win. With `"listed": false` the mounts send
  `icy-do-not-index: 1` instead, with `icy-index-metadata: 1`: RadioBrowser
  honours the opt-out only with both, then marks the entry broken, which hides
  it from most apps. Values are checked: text without control characters
  (C0, DEL, C1, line separators), http(s) URLs, a two-letter country code,
  ISO 639-1 language codes, a latitude from -90 to 90 and a longitude from
  -180 to 180 with at most 6 decimals.
- `autodj` (optional, default `false`, #62): the station plays an AutoDJ
  playlist when no DJ is live. Each of its formats gets a hidden mount
  `/stations/{id}/autodj.{fmt}`, fed by the playout worker over the internal
  network (#63), with the live mount's cap. The live mount sets
  `fallback-mount` to it: when the live source drops, Icecast moves the
  listeners there without a reconnect, and `fallback-override` `all` moves
  them back when the DJ reconnects. A listener who connects while no DJ is
  live hears AutoDJ straight away. Caddy never serves AutoDJ mounts, on
  either host. For a seamless switch the AutoDJ stream must use the live
  stream's codec, bitrate and sample rate. Each AutoDJ mount with a source
  counts toward `<sources>`.
- Capacity planning (which station goes on which node, refusing a full
  node) stays in the control plane; this repository only applies the
  limits. Icecast's global `<sources>` limit (66: 50 live plus 16 AutoDJ
  mounts, #65) is the hard ceiling; the control plane's
  `STREAMING_MAX_SOURCES` must equal it.

Locally, Compose mounts `deploy/stations.example.json` (override with
`STATIONS_JSON`). `tests/station-limits.sh` checks caps, the default cap,
plan formats and bitrates, a reload that keeps listeners, and the AutoDJ
fallback mounts. `tests/autodj.sh` checks the handoff itself ([AutoDJ playout](playout.md#handoff)).

## Opus and data-saver bitrates

Each station can publish two mounts (issue #9):

| Mount                      | Format                | Default bitrate                        | For                                                                                         |
| -------------------------- | --------------------- | -------------------------------------- | ------------------------------------------------------------------------------------------- |
| `/stations/{id}/live.opus` | Ogg Opus, `audio/ogg` | **64 kbps** (48 kbps on the free plan) | Default for listeners: about half the data of MP3 at similar quality                        |
| `/stations/{id}/live.mp3`  | MP3, `audio/mpeg`     | 128 kbps                               | Fallback for players without Ogg Opus (Safari before 18.4, many car and smart-speaker apps) |

- The source sends Ogg Opus with `Content-Type: audio/ogg`; Icecast and
  Caddy pass it through unchanged. The station's plan
  (`stations.json`: `formats`, `max_bitrate_kbps`) decides which mounts and
  bitrates it may publish.
- Measured on production, a 64 kbps Opus stream (stereo, 48 kHz) delivered
  about **35 MB per listener-hour** including the start-up burst (64 KB
  then; 4–8 KB since #85) and
  Ogg framing, against 28.8 MB for the raw bitrate. #12 measures it at load.
- **Web player**: use Opus when the browser supports it, otherwise MP3, and
  label higher quality as an explicit choice ("uses more data"):

  ```js
  const opus = new Audio().canPlayType('audio/ogg; codecs="opus"');
  audio.src = `https://listen.example.com/stations/${id}/live.${opus ? "opus" : "mp3"}`;
  ```

- Browser support (2026): Chrome, Firefox, Edge and Android play Ogg Opus.
  Safari added it in 18.4 but reports describe it as incomplete, so Apple
  devices should get the MP3 mount until tested.
- The desktop app publishes both formats: tropicast/tc-station#36.

`tests/gateway.sh` checks that an Ogg Opus source reaches listeners as
`audio/ogg` and decodes as Opus.

## Source authentication

Broadcasters never use a shared password (issue #7). Each publish to
`/stations/{station-id}/...` is checked by the control-plane endpoint in
`ICECAST_SOURCE_AUTH_URL`, called with the node credentials in
`ICECAST_SOURCE_AUTH_USER` and `ICECAST_SOURCE_AUTH_PASSWORD`. Icecast
denies the source when the endpoint refuses, fails or does not answer
within 15 seconds. [`docs/source-auth.md`](../source-auth.md) describes the contract the API
must implement.

For local runs, Compose starts `auth-stub`, which allows the
`station-id:password` pairs in `STUB_STATIONS`:

```sh
. ./.env
ffmpeg -re -f lavfi -i 'sine=frequency=440' -c:a libmp3lame -b:a 128k \
  -content_type audio/mpeg -f mp3 \
  "icecast://42:change-me@127.0.0.1:${ICECAST_PORT:-8000}/stations/42/live.mp3"
```

`tests/source-auth.sh` checks the auth rules end to end and runs in CI.
