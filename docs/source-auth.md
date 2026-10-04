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
| `action` | `stream_auth` | Always `stream_auth` for a source connect |
| `mount` | `/stations/42/live.mp3` | Requested mount |
| `user` | `42` | Username sent by the desktop app |
| `pass` | `…` | Station broadcast credential |
| `ip` | `203.0.113.7` | Broadcaster IP as seen by Icecast |
| `agent` | `Lavf/63.1.101` | Broadcaster user agent |
| `client` | `17` | Icecast connection ID |
| `server`, `port` | `listen.example.com`, `8000` | Node hostname and port |
| `server-instance` | UUID | Icecast process instance |

## Response

- **Allow:** HTTP 200 with the header `icecast-auth-user: 1`.
- **Deny:** HTTP 200 without that header. Add
  `icecast-auth-message: <reason>` for the Icecast log. Never include the
  credential in the reason.

The endpoint must allow a request only when all of these hold:

1. `mount` matches `/stations/{station-id}/live.(mp3|opus)`.
2. `user` is that station's ID.
3. `pass` matches the station's current, unrevoked credential. Compare in
   constant time.
4. The station's plan allows the requested format.

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
