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
Docker network.

| Host | Allows | Everything else |
|---|---|---|
| `LISTEN_HOST` | `GET`/`HEAD`/`OPTIONS` on `/stations/{id}/live.(mp3\|opus)` | 404 |
| `INGEST_HOST` | `PUT`/`SOURCE` on `/stations/{id}/live.(mp3\|opus)` | 404 |

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

FFmpeg's `icecast://` output does not pass `-ca_file` to its TLS layer, so
it only trusts publicly issued certificates. Against a local gateway,
publish with curl instead:

```sh
ffmpeg -re -f lavfi -i sine -c:a libmp3lame -b:a 64k -f mp3 - |
  curl -k -u 42:change-me -T - -H 'Content-Type: audio/mpeg' -H 'Expect:' \
    https://ingest.localhost/stations/42/live.mp3
```

`tests/gateway.sh` checks routing, TLS, headers and log redaction end to
end and runs in CI.

### CI

`.github/workflows/image.yml` builds the image, runs a health smoke test and
scans it with Trivy, failing on fixable critical vulnerabilities.
Pull requests only build and test. Pushes to `main` and `v*` tags also push
to `ghcr.io/tropicast/icecast`, tagged with the full git SHA and, for tags,
the semver version. No `latest` tag is published: deploy a pinned tag.

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
