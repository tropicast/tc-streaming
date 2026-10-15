# Source authentication contract

Every broadcaster connection to a station mount is checked by the control
plane (ASP.NET Core API). Icecast calls the endpoint below before it
accepts any audio. There is no shared source password for customers.

## Request

Icecast sends `POST {ICECAST_SOURCE_AUTH_URL}` with
`Content-Type: application/x-www-form-urlencoded` and HTTP Basic auth
(`ICECAST_SOURCE_AUTH_USER` / `ICECAST_SOURCE_AUTH_PASSWORD`). The endpoint
must reject requests without these node credentials.

| Field | Example | Meaning |
|---|---|---|
| `action` | `stream_auth` | `stream_auth` for a source connect; `metadata_auth` for a [metadata update](#metadata-updates) |
| `mount` | `/stations/42/live.mp3` | Requested mount |
| `user` | `42` | Username sent by the desktop app |
| `pass` | `…` | Station broadcast credential |
| `ip` | `172.18.0.3` | Address that connected to Icecast. Behind the Caddy gateway this is Caddy's container address, not the broadcaster's |
| `agent` | `Lavf/63.1.101` | Broadcaster user agent |
| `client` | `17` | Icecast connection ID |
| `server`, `port` | `listen.example.com`, `8000` | Node hostname and port |
| `server-instance` | UUID | Icecast process instance |
| `header.ice-bitrate` | `64` | Bitrate the source declares (`Ice-Bitrate`), if sent |
| `header.ice-audio-info` | `bitrate=64;samplerate=44100;channels=2` | `Ice-Audio-Info`, if sent |
| `header.content-type` | `audio/mpeg` | Source content type |

## Response

- **Allow:** HTTP 200 with the header `icecast-auth-user: 1`.
- **Deny:** HTTP 200 without that header. Add
  `icecast-auth-message: <reason>` for the Icecast log. Never include the
  credential in the reason.

The endpoint must allow a request only when all of these hold:

1. `mount` matches `/stations/{station-id}/live.(mp3|opus)`, or
   `/stations/{station-id}/autodj.(mp3|opus)` for a station with AutoDJ (#62).
2. `user` is that station's ID.
3. `pass` matches the station's current, unrevoked credential for that
   mount: a broadcast credential for `live`, the station's AutoDJ credential
   for `autodj` (tc-dashboard#106). Neither is accepted on the other mount.
   Compare in constant time. The auth stub accepts the station credential
   on both.
4. The station's plan allows the requested format (`mp3` or `opus`, from
   the mount).
5. The declared bitrate (`header.ice-bitrate`, else `bitrate=` in
   `header.ice-audio-info`) is not above the plan's limit. A source that
   declares nothing is allowed; egress monitoring (#10) catches abuse.

## Metadata updates

MP3 sources (Liquidsoap, BUTT, Mixxx) send track titles apart from the
audio: `GET /admin/metadata?mode=updinfo&mount=/stations/42/live.mp3&song=…`
with the source's username and password (#72). Ogg sources carry titles in
the stream and do not send them. Icecast calls the same endpoint with
`action=metadata_auth`, and `mount` is then that request's URI, path and
query, for example
`/admin/metadata?mode=updinfo&mount=/stations/42/autodj.mp3&charset=UTF-8&song=Artist%20-%20Title`.
There are no `header.*` fields.

The endpoint must allow it only when:

1. The URI's path is `/admin/metadata`, its query has `mode=updinfo` and
   exactly one `mount`. Read the query parameters, URL-decoded.
2. That `mount` and the `user` and `pass` pass rules 1–4 above, as for a
   source connect to that mount: the station's broadcast credential on its
   live mounts, its AutoDJ credential on its AutoDJ mounts.

It is not a new session: record nothing, and leave the encoding pinned by
the source as it is. A deny is answered like any other; Icecast then
answers the source 401 and keeps the previous title. Icecast sends nothing
else to this role: listener requests and other admin commands never match it
(`icecast.xml`, `match-admin="metadata"`).

## Failure behaviour

- Icecast denies the source when the endpoint is unreachable, returns an
  error or does not answer within 15 seconds. The timeout is built into
  Icecast 2.5 and cannot be configured. Aim to answer in under 1 second.
- Icecast already refuses a second source on a mount that is live, so the
  endpoint does not need to track active sessions.
- A revoked credential takes effect on the next connect. Icecast does not
  re-check sources that are already live.

## Secrets

- The node credentials live only in the node's environment and in the API's
  configuration. Rotate them on both sides together.
- Do not put credentials in `ICECAST_SOURCE_AUTH_URL`. Icecast logs the URL,
  so the entrypoint refuses URLs that contain `@`.

## Local stub

`auth-stub/server.py` implements this contract for development and CI.
`STUB_STATIONS` lists `station-id:password` pairs. Never deploy the stub.
