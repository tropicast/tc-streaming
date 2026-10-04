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

Publish a test tone with FFmpeg:

```sh
. ./.env
ffmpeg -re -f lavfi -i 'sine=frequency=440' -c:a libmp3lame -b:a 128k \
  -content_type audio/mpeg -f mp3 \
  "icecast://source:${ICECAST_SOURCE_PASSWORD}@127.0.0.1:${ICECAST_PORT:-8000}/test.mp3"
```

Listen at `http://127.0.0.1:8000/test.mp3`. Keep `.env` private.

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
