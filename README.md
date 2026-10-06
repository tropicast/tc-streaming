# tc-streaming

Tropicast streaming plane: Icecast origin and TLS gateway infrastructure.
See the epic, tropicast/tc-streaming#1, for the MVP plan.

## Icecast image

`Dockerfile` builds Icecast 2.5.0 and libigloo 0.9.5 from official source
archives with pinned SHA-256 checksums. The runtime stage runs Icecast as a
non-root user. `docker-entrypoint.py` writes the passwords from the
environment into a private copy of `icecast.xml`, then removes them from the
environment before starting Icecast.

### Run locally

```sh
cp .env.example .env
# Fill in .env, e.g. with: openssl rand -hex 24
docker compose up -d --build --wait
curl --fail http://127.0.0.1:8000/status-json.xsl
```

Compose publishes Icecast on localhost only. Set `ICECAST_PORT` in `.env` to
use another host port. `ICECAST_RELAY_PASSWORD` is optional; a random one is
generated at startup when it is unset.

Keep `.env` private. See *Source authentication* below to publish a test
tone.

### Production configuration

`icecast.xml` is the production config for one shared multi-tenant node
(issue #5):

- Each station gets the mounts `/stations/{station-id}/live.mp3` and
  `/stations/{station-id}/live.opus`.
- Limits are sized for a CX33 and its 20 TB monthly egress quota: 1500
  clients and 50 live sources. The config file explains the numbers; the
  load test (#12) will confirm them.
- Icecast is never exposed directly. Caddy is the only public entry point
  and the firewall keeps port 8000 closed.
- Static file serving is off. The root page returns 404, while
  `/status-json.xsl` still works for the healthcheck.
- Logs go to stdout. The access log records the source username, never the
  password.
- `ICECAST_HOSTNAME` sets the public hostname Icecast reports.
- The global source password is an internal break-glass secret only.
- The relay password is generated per node unless `ICECAST_RELAY_PASSWORD`
  is set.
- Compose raises the container's open-file limit to 65536, because each
  listener holds one file descriptor.

### Station limits

Each station gets its own Icecast mounts with a listener cap (issue #8).
`stations.json` holds the desired state, from the control plane:

```json
{
  "default": {"max_listeners": 100},
  "stations": {
    "42": {"plan": "free", "max_listeners": 100, "max_bitrate_kbps": 64, "formats": ["mp3", "opus"]}
  }
}
```

- `max_listeners`: a listener above the cap gets `503`. Stations without an
  entry use `default.max_listeners` (the free-tier cap).
- `formats` and `max_bitrate_kbps` are checked by the source auth endpoint
  when a station connects, using the bitrate the source declares
  (`Ice-Bitrate` / `Ice-Audio-Info`). See `docs/source-auth.md`.
- The entrypoint renders one `<mount>` per station and format, with a copy
  of the source authentication. `docker-entrypoint.py reload-stations`
  re-renders them and reloads Icecast with `SIGHUP`: live listeners and
  sources stay connected.
- Capacity planning (which station goes on which node, refusing a full
  node) stays in the control plane; this repository only applies the
  limits. Icecast's global `<sources>` limit (50) is the hard ceiling.

Locally, Compose mounts `deploy/stations.example.json` (override with
`STATIONS_JSON`). `tests/station-limits.sh` checks caps, the default cap,
plan formats and bitrates, and a reload that keeps listeners.

### Source authentication

Broadcasters never use a shared password (issue #7). Each publish to
`/stations/{station-id}/...` is checked by the control-plane endpoint in
`ICECAST_SOURCE_AUTH_URL`, called with the node credentials in
`ICECAST_SOURCE_AUTH_USER` and `ICECAST_SOURCE_AUTH_PASSWORD`. Icecast
denies the source when the endpoint refuses, fails or does not answer
within 15 seconds. `docs/source-auth.md` describes the contract the API
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

### TLS gateway

Caddy (`caddy/Caddyfile`) is the only public entry point (issue #6). It
runs in the same Compose project and reaches Icecast over the internal
Docker network. It is built with the
[layer4 module](https://github.com/mholt/caddy-l4) (`caddy/Dockerfile`).

| Host | Allows | Everything else |
|---|---|---|
| `LISTEN_HOST` | `GET`/`HEAD`/`OPTIONS` on `/stations/{id}/live.(mp3\|opus)` | 404 |
| `INGEST_HOST` | `PUT`/`SOURCE` on `/stations/{id}/live.(mp3\|opus)` | connection closed |

The two hosts work differently:

- **Listeners** go through Caddy's HTTP reverse proxy.
- **Broadcasters** do not. Icecast source clients (the desktop app, BUTT,
  Mixxx, FFmpeg's `icecast://`) send `PUT` or `SOURCE` with no
  `Content-Length` and stream until they disconnect. An HTTP proxy forwards
  no body for such a request. On `INGEST_HOST`, Caddy's layer4 route
  decrypts TLS (HTTP/1.1 only), checks the request line and passes the raw
  connection to Icecast. Chunked uploads (curl, FFmpeg's `https://`) work
  too.

- Streams are proxied with `flush_interval -1`, so audio is never
  buffered. Caddy sets no timeout on long-lived streams.
- Admin and status pages are never reachable from outside.
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

### CI

Every workflow runs only when the files it covers change, so a docs-only
change runs nothing. A newer push to a pull request cancels its running
checks; runs on `main` always finish.

| Workflow | Runs when | Does |
|---|---|---|
| `image.yml` | Icecast image files change (PR, `main`), `v*` tags | Build, health smoke test, Trivy. On `main`/tags, push `ghcr.io/tropicast/icecast` |
| `caddy-image.yml` | `caddy/Dockerfile` changes (PR, `main`) | Build, layer4 check, Trivy. On `main`, push `ghcr.io/tropicast/caddy` |
| `e2e.yml` | Images, Compose, auth stub or tests change | One job: builds both images once, runs `tests/source-auth.sh` and `tests/gateway.sh` |
| `deploy-lint.yml`, `terraform.yml`, `ansible.yml` | Their own files change | Lint and validate |

Jobs run where the repository variable `RUNS_ON` says: the self-hosted
runner host (`["self-hosted","linux","x64"]`, two jobs at a time), or
GitHub-hosted `ubuntu-latest` when it is unset. Workflows and tests use
per-run image tags, Compose projects, ports and Docker config, so parallel
jobs on one host do not collide. See
[docs/how-to/set-up-ci-runner.md](docs/how-to/set-up-ci-runner.md).

Images are tagged with the full git SHA (plus semver for Icecast tags); no
`latest` tag is published. The `push` path filters of the two image
workflows must match the path lists in `deploy.yml`, because a deploy uses
the image of the last `main` commit that touched those paths.

Builds share the GitHub Actions cache by image (`scope=icecast`,
`scope=caddy`), so e2e and pull requests reuse what `main` built. The Trivy
database is cached for a day. Run the e2e tests locally with
`tests/source-auth.sh` and `tests/gateway.sh` (they build the images
themselves unless `E2E_PREBUILT=1`).

## MVP node (Terraform)

`infra/terraform` provisions the MVP streaming node on Hetzner Cloud
(issue #3):

- 1× **CX33** (4 vCPU, 8 GB RAM, 20 TB egress included) in `fsn1`.
- IPv4 and IPv6 primary IPs that outlive the server, so a rebuilt node keeps
  its addresses and DNS.
- A firewall that opens 80/443 (TCP, plus UDP 443 for HTTP/3) to everyone and
  22 only to `admin_cidrs`. Icecast's port 8000 is never public.
- Key-only SSH. Delete and rebuild protection on the server and IPs.
- Optional `A`/`AAAA` records for `listen.<zone>` and `ingest.<zone>` in an
  existing Hetzner DNS zone.

Cost: about $10-14/month for the CX33 plus a small charge for the primary
IPv4; egress above 20 TB is billed at about $1.12/TB. Check current Hetzner
prices before applying.

```sh
cd infra/terraform
cp backend.hcl.example backend.hcl            # remote state bucket
cp terraform.tfvars.example terraform.tfvars  # keys, admin CIDRs, DNS zone
export HCLOUD_TOKEN=...                       # Hetzner Cloud API token
export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...  # state bucket keys
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

To provision from GitHub Actions instead, follow
[docs/how-to/provision-hetzner-with-ci.md](docs/how-to/provision-hetzner-with-ci.md).

`backend.hcl`, `terraform.tfvars` and state files are git-ignored. Delete
protection must be turned off in `main.tf` before `terraform destroy` can
remove the server or IPs.

## Node hardening (Ansible)

`infra/ansible/site.yml` prepares a node created by Terraform (issue #4):

- Users: `ops` for admins (sudo) and `deploy` for the deploy pipeline (no
  sudo, `docker` group). Membership of the `docker` group is
  root-equivalent, so only the pipeline key logs in as `deploy`.
- SSH: keys only, no root login, only `ops` and `deploy` allowed.
  fail2ban bans repeated failures.
- Unattended security upgrades, with automatic reboots turned **off**:
  a reboot drops every listener. Reboot by hand in the maintenance window.
- Time zone UTC with NTP sync.
- Kernel tuning for many long-lived connections, BBR congestion control,
  and a high open-file limit for services.
- Docker Engine and the Compose plugin from Docker's apt repository.
  `live-restore` keeps containers running while the Docker daemon
  restarts. Logs rotate (`local` driver, 5 × 20 MB per container).
  Containers get a 65536 open-file limit.
- `/opt/tc-streaming`, owned by `deploy`, for the Compose project. Secrets
  (`.env`) are written there at deploy time (#11) and never committed.

```sh
cd infra/ansible
cp inventory.example.ini inventory.ini
mkdir -p group_vars && cp group_vars_example.yml group_vars/streaming.yml
uvx --from ansible ansible-playbook site.yml   # or: ansible-playbook site.yml
```

Run it first as `root`. That run turns off root login, so set
`ansible_user=ops` in `inventory.ini` for later runs.

## Deploy and operations

`deploy/compose.yaml` is the production stack: Icecast from GHCR with no
published port, and Caddy on ports 80/443. The **Deploy** workflow
(`.github/workflows/deploy.yml`) ships it to the node and
`deploy/deploy.sh` activates it, keeping the last 5 releases for rollback
(issue #11).

[docs/runbook.md](docs/runbook.md) covers first-time setup, deploys,
rollbacks, what restarts what, and incidents.

## Monitoring

`exporter/icecast_exporter.py` (station listeners and bytes, Hetzner
monthly traffic) and Grafana Alloy (`deploy/alloy/config.alloy`) run on the
node with the Compose profile `monitoring` and push to Grafana Cloud.
Alert rules (`monitoring/rules.yaml`, unit-tested with
`monitoring/rules.test.yaml`) and a dashboard (`monitoring/dashboard.json`)
are loaded there. See
[docs/how-to/set-up-monitoring.md](docs/how-to/set-up-monitoring.md)
(issue #10).
