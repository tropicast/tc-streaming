<p align="center">
  <img src="docs/assets/tropicast-logo.svg" alt="Tropicast logo" width="120" height="120">
</p>

<h1 align="center">Tropicast Streaming</h1>

<p align="center">
  Streaming plane for Tropicast: an Icecast origin behind a Caddy TLS gateway, with per-station limits, source auth and monitoring.
</p>

<p align="center">
  <a href="https://github.com/tropicast/tc-streaming/actions/workflows/image.yml"><img src="https://github.com/tropicast/tc-streaming/actions/workflows/image.yml/badge.svg?branch=main" alt="Icecast image"></a>
  <a href="https://github.com/tropicast/tc-streaming/actions/workflows/caddy-image.yml"><img src="https://github.com/tropicast/tc-streaming/actions/workflows/caddy-image.yml/badge.svg?branch=main" alt="Caddy image"></a>
  <a href="https://github.com/tropicast/tc-streaming/actions/workflows/e2e.yml"><img src="https://github.com/tropicast/tc-streaming/actions/workflows/e2e.yml/badge.svg?branch=main" alt="E2E"></a>
  <a href="https://github.com/tropicast/tc-streaming/actions/workflows/deploy-lint.yml"><img src="https://github.com/tropicast/tc-streaming/actions/workflows/deploy-lint.yml/badge.svg?branch=main" alt="Deploy lint"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/tropicast/tc-streaming" alt="License: Apache-2.0"></a>
  <a href="Dockerfile"><img src="https://img.shields.io/badge/Icecast-2.5.0-4B5563" alt="Icecast 2.5.0"></a>
  <a href="caddy/Dockerfile"><img src="https://img.shields.io/badge/Caddy-2.11-1F88C0?logo=caddy&logoColor=white" alt="Caddy 2.11"></a>
</p>

Broadcasters publish to `ingest.<domain>` with the desktop app
([tc-station](https://github.com/tropicast/tc-station)) or any Icecast source
client; listeners play `listen.<domain>`. The control plane
([tc-dashboard](https://github.com/tropicast/tc-dashboard)) decides who may
publish and sets each station's limits.

```text
 broadcaster --TLS--> Caddy (ingest, layer4) --raw--> Icecast 2.5 <--HTTP-- Caddy (listen) <--TLS-- listener
                                                         |   ^
                       source auth: tc-dashboard <-------+   +---- stations.json (limits, from tc-dashboard)
                       exporter + Alloy ----------> Grafana Cloud (metrics, logs)
```

## Features

- Icecast 2.5.0 built from pinned sources, non-root, passwords kept out of the environment.
- Two mounts per station: Ogg Opus (data saver) and MP3, at `/stations/{id}/live.(opus|mp3)`.
- Per-station listener caps, formats and bitrates from `stations.json`, reloaded with no disconnects.
- Source authentication against the control plane: no shared broadcast password.
- Caddy TLS gateway: HTTP proxy for listeners, layer4 pass-through for sources, Let's Encrypt certificates.
- RadioBrowser listing metadata (`icy-*` headers) per station.
- AutoDJ: hidden fallback mounts and a Liquidsoap playout service that plays each station's playlist when no DJ is live.
- Metrics, alerts, dashboard and logs in Grafana Cloud.
- Hetzner node with Terraform, hardened with Ansible, deployed by a manual workflow with rollback.

## Quick start

Needs Docker with Compose.

```sh
cp .env.example .env
# Fill in .env, e.g. with: openssl rand -hex 24
docker compose up -d --build --wait
curl --fail http://127.0.0.1:8000/status-json.xsl
```

Compose runs Icecast (on localhost only), the TLS gateway on `*.localhost`
with local certificates, and an auth stub that allows the
`station-id:password` pairs in `STUB_STATIONS`. Publish a test tone:

```sh
. ./.env
ffmpeg -re -f lavfi -i 'sine=frequency=440' -c:a libmp3lame -b:a 128k \
  -content_type audio/mpeg -f mp3 \
  "icecast://42:change-me@127.0.0.1:${ICECAST_PORT:-8000}/stations/42/live.mp3"
```

## Build and test

```sh
tests/source-auth.sh     # source auth rules end to end
tests/gateway.sh         # TLS gateway: routing, both upload styles, headers, log redaction
tests/station-limits.sh  # caps, plan formats and bitrates, reload keeping listeners
tests/monitoring.sh      # exporter metrics and Icecast logs, against a local Prometheus and Loki
```

They build the images themselves (set `E2E_PREBUILT=1` to reuse them). CI
workflows and what they run: [docs/how-to/build-and-test.md](docs/how-to/build-and-test.md).

## Layout

| Path                                                | Contents                                            |
| --------------------------------------------------- | --------------------------------------------------- |
| `Dockerfile`, `docker-entrypoint.py`, `icecast.xml` | Icecast image, config rendering, station mounts     |
| `caddy/`                                            | Caddy image with the layer4 module, `Caddyfile`     |
| `auth-stub/`                                        | Local source auth stand-in                          |
| `playout/`                                          | AutoDJ playout image (Liquidsoap + supervisor)      |
| `exporter/`, `monitoring/`                          | Icecast exporter, alert rules and Grafana dashboard |
| `infra/terraform`, `infra/ansible`                  | Hetzner node, hardening                             |
| `deploy/`                                           | Production Compose file, `deploy.sh`, Alloy config  |
| `tests/`, `tools/loadtest`                          | End-to-end tests, load test                         |

## Documentation

| Topic                                                             | Covers                                                               |
| ----------------------------------------------------------------- | -------------------------------------------------------------------- |
| [Icecast](docs/reference/icecast.md)                              | Image, production config, station limits, Opus mounts, source auth   |
| [TLS gateway](docs/reference/gateway.md)                          | Caddy routing for listen and ingest, headers, certificates           |
| [Source auth contract](docs/source-auth.md)                       | The endpoint the control plane implements                            |
| [AutoDJ playout](docs/reference/playout.md)                       | Playout service, playout endpoint contract, settings                 |
| [Infrastructure and operations](docs/reference/infrastructure.md) | Terraform node, Ansible hardening, deploy, monitoring                |
| [Runbook](docs/runbook.md)                                        | First-time setup, deploys, rollbacks, restarts, incidents            |
| [Provision with CI](docs/how-to/provision-hetzner-with-ci.md)     | Terraform from GitHub Actions                                        |
| [Set up monitoring](docs/how-to/set-up-monitoring.md)             | Grafana Cloud metrics, logs, alerts and dashboard                    |
| [Build and test](docs/how-to/build-and-test.md)                   | CI workflows, image tags, caches                                     |
| [Load test](docs/load-test.md)                                    | Capacity of one node                                                 |
| [Changelog](CHANGELOG.md)                                         | Changes per release; releasing: [runbook](docs/runbook.md#releasing) |

## Contributing

One issue, one branch (`feat/…`, `fix/…`, `docs/…`, `ci/…`) and one pull
request. CI must pass before review. Each workflow runs only when the files it
covers change. Add changes to the `Unreleased` section of
[CHANGELOG.md](CHANGELOG.md); releases are tag-driven
([Releasing](docs/runbook.md#releasing)).

## License

Copyright 2026 Tropicast. Licensed under the [Apache License, Version 2.0](LICENSE);
see [NOTICE](NOTICE). The license does not grant use of the Tropicast name or
logo (section 6).

## Responsible use

- The software is provided "AS IS", without warranties or conditions of any
  kind. The authors and Tropicast are not liable for any damages or claims
  arising from its use (Apache License 2.0, sections 7 and 8).
- You are responsible for what you broadcast or host with it: rights and
  royalties for music and other content, and the broadcasting, privacy and
  other laws that apply to you and your listeners.
- Do not use it to distribute content you have no right to distribute, or for
  any unlawful purpose.
