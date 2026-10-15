# TLS gateway

Caddy (`caddy/Caddyfile`) is the only public entry point (issue #6). It
runs in the same Compose project and reaches Icecast over the internal
Docker network. It is built with the
[layer4 module](https://github.com/mholt/caddy-l4) (`caddy/Dockerfile`).

| Host          | Allows                                                                                                                           | Everything else   |
| ------------- | -------------------------------------------------------------------------------------------------------------------------------- | ----------------- |
| `LISTEN_HOST` | `GET`/`HEAD`/`OPTIONS` on `/stations/{id}/live.(mp3\|opus)`                                                                      | 404               |
| `INGEST_HOST` | `PUT`/`SOURCE` on `/stations/{id}/live.(mp3\|opus)`; `GET /admin/metadata?mode=updinfo&mount=/stations/{id}/live.(mp3\|opus)` | connection closed |

The two hosts work differently:

- **Listeners** go through Caddy's HTTP reverse proxy.
- **Broadcasters** do not. Icecast source clients (the desktop app, BUTT,
  Mixxx, FFmpeg's `icecast://`) send `PUT` or `SOURCE` with no
  `Content-Length` and stream until they disconnect. An HTTP proxy forwards
  no body for such a request. On `INGEST_HOST`, Caddy's layer4 route
  decrypts TLS (HTTP/1.1 only), checks the request line and passes the raw
  connection to Icecast. Chunked uploads (curl, FFmpeg's `https://`) work
  too.
- **Track titles** of MP3 sources are a separate request, an ICY metadata
  update (`GET /admin/metadata?mode=updinfo&mount=…&song=…`) with the
  source's credentials. The ingest route passes it for a live mount only;
  Icecast checks the credentials with the control plane, as for the source
  ([contract](../source-auth.md#metadata-updates)). No other admin command
  passes.

- Streams are proxied with `flush_interval -1`, so audio is never
  buffered. Caddy sets no timeout on long-lived streams.
- Admin and status pages are never reachable from outside; the only admin
  request that passes is a source's own metadata update, on `INGEST_HOST`.
- Listener responses carry `Access-Control-Allow-Origin: *` for the web
  player, and every response carries HSTS.
- The access log drops query strings, `Authorization` and `Cookie` headers.
- Certificates come from Let's Encrypt. Set real hostnames, `ACME_EMAIL`,
  `CADDY_BIND=0.0.0.0` and leave `CADDY_GLOBAL_OPTIONS` empty in
  production. Locally, `.env.example` uses `*.localhost` with
  `local_certs`.

Against production, any Icecast source client works:

```sh
ffmpeg -re -f lavfi -i sine -c:a libmp3lame -b:a 64k \
  -content_type audio/mpeg -f mp3 -tls 1 \
  "icecast://42:<password>@ingest.example.com:443/stations/42/live.mp3"
```

FFmpeg's `icecast://` output does not pass `-ca_file` to its TLS layer, so
it cannot trust a local gateway's certificate. Locally, publish with
`tests/raw_source.py` (same protocol) instead:

```sh
ffmpeg -re -f lavfi -i sine -c:a libmp3lame -b:a 64k -f mp3 - |
  python3 tests/raw_source.py ingest.localhost 443 /stations/42/live.mp3 \
    42:change-me --ca root.crt   # root.crt: Caddy's local CA, see tests/gateway.sh
```

`tests/gateway.sh` checks routing, TLS, both upload styles, headers and log
redaction end to end and runs in CI. `.github/workflows/caddy-image.yml`
builds the Caddy image and publishes `ghcr.io/tropicast/caddy` from
`main`.
