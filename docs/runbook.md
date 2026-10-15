# Streaming node runbook

How to deploy, roll back and operate the MVP streaming node (issue #11).
The node is created by Terraform
([how-to](how-to/provision-hetzner-with-ci.md)) and hardened by Ansible
([Node hardening](reference/infrastructure.md#node-hardening-ansible)).

## What runs on the node

`/opt/tc-streaming`, owned by `deploy`:

| Path | Content |
|---|---|
| `.env` | Secrets and settings, written by every deploy (mode 0600) |
| `compose.yaml` | Active Compose file (`deploy/compose.yaml` in git) |
| `caddy/Caddyfile` | Active Caddy config |
| `auth-stub/server.py` | Temporary auth stub (only with `COMPOSE_PROFILES=stub`) |
| `deploy.sh` | Activates releases, rolls back, shows status |
| `releases/<sha>/` | The last 5 deployed bundles, for rollback |
| `CURRENT`, `PREVIOUS` | `<git-sha> <image-tag>` of the active and prior release |

Services (Compose project `tc-streaming`): `icecast` (no published port),
`caddy` (ports 80/443, TCP and UDP), `auth-stub` when the `stub`
profile is on, and `playout` (no published port) when the `autodj` profile
is on.

## What a deploy restarts

| Change | Effect on listeners |
|---|---|
| Caddyfile only | None. Caddy reloads its config in place. |
| Icecast image (Dockerfile, `icecast.xml`, entrypoint) | Icecast restarts. All listeners and broadcasters disconnect; the desktop app reconnects by itself, players usually need a retry. |
| Icecast secrets or settings in `.env` | Same as an image change. |
| Caddy image (`caddy/Dockerfile`: Caddy or caddy-l4 version) | Caddy restarts. All connections drop for a few seconds. |
| Playout image (`playout/`) or `PLAYOUT_*` settings | Playout restarts. Listeners who are on AutoDJ at that moment disconnect; live stations are not affected. |

The deploy uses the Icecast, Caddy and playout images of the last `main`
commits that changed their files (`ghcr.io/tropicast/icecast`,
`ghcr.io/tropicast/caddy`, `ghcr.io/tropicast/playout`). A deploy that does
not touch them keeps them running. The bundle's `release.env` records the
tags.
Deploy Icecast changes in a quiet hour.

## First-time setup

Do this once, after Terraform and Ansible.

### 1. DNS

`listen.<domain>` and `ingest.<domain>` must resolve to the node (A and
AAAA). With a Cloudflare-registered domain, add them in Cloudflare as
**DNS only**: the Cloudflare proxy caps upload bodies and would cut
broadcasts.

```sh
dig +short listen.<domain> @1.1.1.1   # node IPv4
dig +short ingest.<domain> @1.1.1.1   # node IPv4
```

Caddy cannot get certificates until both names resolve.

### 2. Deploy SSH key and host key

The deploy key is the one whose public half is in `deploy_ssh_keys`
(Ansible). Store the private half and pin the node's host key:

```sh
gh secret set DEPLOY_SSH_KEY < ~/.ssh/tropicast_deploy
gh variable set DEPLOY_HOST --body <ipv4>

ssh-keyscan -t ed25519 <ipv4> > /tmp/node_known_hosts
ssh-keygen -lf /tmp/node_known_hosts   # fingerprint just fetched
ssh-keygen -lF <ipv4>                  # fingerprint you accepted on first login
```

Continue only if the two ED25519 fingerprints match. Otherwise CI could
trust an impostor.

```sh
gh variable set DEPLOY_KNOWN_HOSTS < /tmp/node_known_hosts
```

### 3. Secrets

Generate the Icecast secrets once and keep them only in GitHub:

```sh
for name in ICECAST_SOURCE_PASSWORD ICECAST_ADMIN_PASSWORD \
            ICECAST_RELAY_PASSWORD ICECAST_SOURCE_AUTH_PASSWORD; do
  openssl rand -hex 24 | gh secret set "$name"
done
```

`ICECAST_SOURCE_AUTH_PASSWORD` is shared with the control-plane API: the
API must accept it as the Basic auth password from Icecast
(`docs/source-auth.md`).

### 4. Settings

```sh
gh variable set LISTEN_HOST --body listen.<domain>
gh variable set INGEST_HOST --body ingest.<domain>
gh variable set ACME_EMAIL --body ops@<domain>
gh variable set ICECAST_SOURCE_AUTH_URL --body https://<api-host>/icecast/source
# Optional, default "icecast":
gh variable set ICECAST_SOURCE_AUTH_USER --body icecast
```

**Control plane on the private network** (tc-dashboard `infra/terraform`
attaches this node at `10.20.1.2`): the exporter (Compose profile
`monitoring`) then also listens on that address, port 9100, so the control
plane reads live status, listeners and egress without Icecast credentials.

```sh
gh variable set PRIVATE_IP --body 10.20.1.2
```

Without `PRIVATE_IP` the exporter port stays on loopback.

**Until the API exists**, run the auth stub on the node instead:

```sh
gh variable set COMPOSE_PROFILES --body stub
gh variable set ICECAST_SOURCE_AUTH_URL --body http://auth-stub:9000/icecast/source
printf '42:%s\n' "$(openssl rand -hex 16)" | gh secret set STUB_STATIONS
```

The stub accepts the `station-id:password` pairs in `STUB_STATIONS`. It is
for testing only: remove the `stub` profile and point
`ICECAST_SOURCE_AUTH_URL` at the API before real stations go live.

## Deploy

```sh
gh workflow run deploy.yml --ref main            # deploys the head of main
gh workflow run deploy.yml --ref main -f ref=v0.1.0   # deploys a release
gh run watch
```

A release tag deploys the same images as its commit (the `sha-` tags). The
deploy records the version in `release.env`; the exporter reports it as
`tc_streaming_build_info{version=…}`, and `deploy.sh status` shows it. A
commit without a tag reports `git describe`, e.g. `0.1.0-3-gabc1234`.

The workflow:

1. Checks that the commit is on `main` and that its images exist in GHCR.
2. Opens SSH to the runner's own IPv4 only: it attaches a temporary Hetzner
   firewall (`ci-deploy-<run-id>`, label `purpose=ci-deploy`) with
   `HCLOUD_TOKEN`. A final step always removes it, and the next deploy
   removes any leftover.
3. Writes `.env` on the node from GitHub secrets and variables (over SSH
   stdin, never on a command line).
4. Uploads the bundle (`deploy/compose.yaml`, `deploy/deploy.sh`,
   `caddy/Caddyfile`, `auth-stub/server.py`) and `release.env` with the
   image tags.
5. Logs the node in to GHCR with the job's short-lived token, runs
   `deploy.sh activate`, then logs out.
6. Checks that `https://<listen>/admin/stats.xml` and
   `/status-json.xsl` return 404 through Caddy.

Only one deploy runs at a time. While a deploy runs, a Terraform plan
shows the temporary firewall as a change to the server; do not apply it
until the deploy has finished.

Optional variable: `DEPLOY_SERVER`, the Hetzner server name (default
`tc-stream-1`). The repository's free plan has no
environment approvals, so whoever starts the workflow is the approver.

## Roll back

From GitHub, deploy an older commit of `main` or an older release tag:

```sh
gh workflow run deploy.yml --ref main -f ref=<older-sha-or-tag>
```

`deploy.sh status` on the node, or the summary of an earlier deploy run,
shows previous SHAs.

Without GitHub (for example during a GitHub outage), on the node:

```sh
ssh -i ~/.ssh/tropicast_deploy deploy@<ipv4>
/opt/tc-streaming/deploy.sh rollback   # back to PREVIOUS, using the local image
/opt/tc-streaming/deploy.sh status
```

The next deploy from GitHub rewrites `.env`. To roll back a secret, change
it in GitHub first.

## Releasing

The git tag is the only place the version is set; nothing in the repository
holds it. Local and CI runs report `0.0.0`.

1. In a PR, rename `## [Unreleased]` in `CHANGELOG.md` to
   `## [x.y.z] - YYYY-MM-DD` and add a new empty `Unreleased` section. Merge it.
2. Tag the merge commit on main:

   ```sh
   git switch main && git pull
   git tag v0.1.0-rc.1 && git push origin v0.1.0-rc.1   # or v0.1.0
   ```

3. The *Release* workflow:
   - checks the tag format (`v1.2.3` or `v1.2.3-rc.1`), that the commit is on
     main, and that `CHANGELOG.md` has a section for the version (pre-release
     tags use their base version);
   - checks the exporter reports the version;
   - adds `:<version>` (plus `:latest` for non-pre-release tags) to the
     `icecast` and `caddy` images of that commit with `crane tag`, waiting for
     them if main is still building them. The digests stay the same, so a
     release deploy restarts nothing but the exporter;
   - creates a **draft** GitHub Release: the changelog section, the images,
     then the merged PRs grouped by label (`.github/release.yml`; label a PR
     `skip-changelog` to omit it).
4. Review the draft and publish it.
5. Deploy with `ref=v<version>` (above). In Grafana, the dashboard's
   **Release** panel shows the version.

## Everyday checks

Icecast logs are in Grafana (dashboard *Tropicast streaming node*, panel
*Icecast logs*, or **Explore** with the `grafanacloud-<stack>-logs` data
source). Useful queries:

```text
{job="icecast", level=~"error|warn"}                     # problems only
{job="icecast"} | station="42"                           # one station
{job="icecast", log_type="access"} | status=~"401|403"   # refused sources and admin calls
{job="icecast", log_type="error"} |= "auth_url"          # auth endpoint answers
```

On the node (also for Caddy, whose logs are not shipped yet):

```sh
ssh -i ~/.ssh/tropicast_deploy deploy@<ipv4>
/opt/tc-streaming/deploy.sh status
/opt/tc-streaming/deploy.sh compose logs --tail 100 icecast caddy
```

Plain `docker compose` fails on the node without the release's image tags;
`deploy.sh compose …` loads them and passes the rest to `docker compose`.

## Monitoring

Grafana Cloud collects node and station metrics and Icecast logs, and sends
the alerts in `monitoring/rules.yaml`. Setup:
[how-to/set-up-monitoring.md](how-to/set-up-monitoring.md). The exporter,
Alloy and docker-socket-proxy run on the node with the Compose profile
`monitoring`.

## Change station limits

Station caps, formats and bitrates live in `/opt/tc-streaming/stations.json`
(see [Station limits](reference/icecast.md#station-limits)). Applying them never restarts Icecast.

- **Control plane (normal):** the dashboard renders the file from its database
  and pushes it over SSH with a provisioning key, which the node restricts to
  `deploy.sh apply-stations` (`provisioning_ssh_keys` in Ansible). It
  re-applies within seconds of a change and retries failures. Its operator
  view (`GET /api/v1/operator/streaming-nodes`) shows the applied version and
  errors.
- **`STATION_LIMITS` (fallback):** when the repository variable is set, every
  deploy writes it to the node. When it is unset, a deploy keeps the node's
  file. Delete the variable once the control plane pushes limits, or the next
  deploy overwrites them until the control plane re-applies (at most 30 s).

```sh
gh variable set STATION_LIMITS < stations.json   # then deploy, or on the node:
ssh -i ~/.ssh/tropicast_deploy deploy@<ipv4> /opt/tc-streaming/deploy.sh apply-stations < stations.json
```

Lowering a cap does not disconnect listeners already connected; it only
refuses new ones above the cap.

## AutoDJ

The `playout` service plays each AutoDJ station's playlist to its hidden
AutoDJ mounts; Icecast moves a station's listeners there when its DJ drops.
Design and endpoint contract: [AutoDJ playout](reference/playout.md).

**Turn it on** once the control plane serves the playout endpoint
(tc-dashboard#107) on the private network:

```sh
gh variable set PLAYOUT_URL --body http://10.20.1.10:8081/internal/playout
openssl rand -hex 24 | tee ~/.tropicast_playout | gh secret set PLAYOUT_PASSWORD   # same value in tc-dashboard
gh variable set COMPOSE_PROFILES --body monitoring,autodj
gh workflow run deploy.yml --ref main
```

`PLAYOUT_USER` is optional (default `playout`), and so are `PLAYOUT_CPUS`
and `PLAYOUT_MEMORY` (default `1.5` and `2g`; sizing in
[load-test.md](load-test.md#autodj-playout)). Set the control plane's
`STREAMING_MAX_SOURCES` to `66`, Icecast's `<sources>`. The deploy fails early when
the `autodj` profile is on and `PLAYOUT_URL` or `PLAYOUT_PASSWORD` is
missing. A station plays AutoDJ only when it has `"autodj": true` in
`stations.json` (the mounts) and appears in the playout endpoint (the
playlist).

**Check:**

```sh
ssh -i ~/.ssh/tropicast_deploy deploy@<ipv4> /opt/tc-streaming/deploy.sh compose logs --tail 50 playout   # "[playout] station 42: started"
ssh -i ~/.ssh/tropicast_deploy deploy@<ipv4> /opt/tc-streaming/deploy.sh compose ps playout              # healthy
```

**When playout is down**, live stations are not affected. Listeners on
AutoDJ at that moment disconnect; while it is down, a station without a DJ
has no audio and its live mount answers 404, as without AutoDJ. Docker
restarts the service (`restart: unless-stopped`).

**Alerts** (Grafana, profile `monitoring`): PlayoutDown, AutoDJSourceMissing,
StationOffAir, PlayoutEndpointFailing and PlayoutStationRestarting
([what they mean](how-to/set-up-monitoring.md#what-the-alerts-mean)). The
dashboard's *Stations on live vs AutoDJ* panel shows which stations play
what. After adding the rules, run step 6 of the monitoring how-to again to
load them.

**Common log lines:**

| Line | Meaning |
|---|---|
| `cannot read the desired state, keeping N stations: …` | The endpoint is unreachable or refuses; stations keep their last playlist. Check `PLAYOUT_URL`, the password on both sides and the private network. |
| `track <id>: download failed: …` | Presigned URL expired or wrong, sha256 mismatch, file too large or not audio. The rest of the playlist plays. |
| `station <id>: no playable track` | Every track failed: the station has no AutoDJ. |
| `station <id>: liquidsoap exited with …` | Restarted with backoff; the Liquidsoap lines above it say why. |

A station that connects but is refused by Icecast (wrong AutoDJ credential)
shows Liquidsoap connection errors and an `auth` denial in the Icecast log.

**Turn it off:** remove `autodj` from `COMPOSE_PROFILES` and deploy. The
fallback mounts stay until the control plane drops `"autodj": true`; they
are harmless without a source.

## Incidents

### Node is down or destroyed

1. Recreate it: run the Terraform deploy workflow (plan, then apply). The
   primary IPs survive, so DNS needs no change.
2. The new server has a new host key. Update `DEPLOY_KNOWN_HOSTS` (step 2
   above) and remove the old key locally: `ssh-keygen -R <ipv4>`.
3. Run the Ansible playbook as `root` once ([Node hardening](reference/infrastructure.md#node-hardening-ansible)).
4. Run the Deploy workflow.

Caddy requests new certificates on the new node. Let's Encrypt allows 5
identical certificates per week, so avoid rebuilding the node more than a
few times a week.

Target: back online in under 30 minutes.

### Certificates fail

Symptoms: browsers show TLS errors, or `caddy` logs `obtaining certificate`
errors.

- Both hostnames must resolve to the node (`dig @1.1.1.1`).
- Port 80 must be reachable for the ACME HTTP challenge (Hetzner firewall).
- Cloudflare records must be **DNS only**.
- Check `/opt/tc-streaming/deploy.sh compose logs caddy | grep -i acme`.

### Broadcasters are all rejected

Icecast denies every source when the auth endpoint is down, slow (over 15
seconds) or rejects Icecast's own credentials. Stations already live are
not affected.

- Check the Icecast log: `auth_url/url_add_client` lines show the reason.
  In Grafana: `{job="icecast", log_type="error"} |= "auth_url"`, or the
  dashboard panel *Rejected broadcasters*.
- Check the API's health and that `ICECAST_SOURCE_AUTH_URL` and
  `ICECAST_SOURCE_AUTH_PASSWORD` match on both sides.

### Egress near the 20 TB quota

The Hetzner Console shows the server's monthly traffic (**Servers →
tc-stream-1 → Graphs/Traffic**). Above 20 TB, Hetzner bills about
$1.12/TB.

- At **70%** of the quota, or when several Starter stations are live at the
  same time, plan a second node (Growth stage in the epic).
- Lower default bitrates (Opus 48-64 kbps, #9) cut egress per listener.

### Reboots and updates

Security updates install automatically but never reboot the node, because
a reboot drops every listener. When `/var/run/reboot-required` exists,
reboot in a quiet hour:

```sh
ssh -i ~/.ssh/tropicast_admin ops@<ipv4>
test -f /var/run/reboot-required && sudo reboot
```

Docker restarts both services after the reboot (`restart: unless-stopped`).

## Rotate a secret

1. Set the new value: `openssl rand -hex 24 | gh secret set <NAME>`.
2. For `ICECAST_SOURCE_AUTH_PASSWORD`, update the API at the same time.
3. Run the Deploy workflow. Icecast restarts, so do it in a quiet hour.
