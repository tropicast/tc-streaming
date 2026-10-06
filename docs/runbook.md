# Streaming node runbook

How to deploy, roll back and operate the MVP streaming node (issue #11).
The node is created by Terraform
([how-to](how-to/provision-hetzner-with-ci.md)) and hardened by Ansible
(README, *Node hardening*).

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
`caddy` (ports 80/443, TCP and UDP), and `auth-stub` when the `stub`
profile is on.

## What a deploy restarts

| Change | Effect on listeners |
|---|---|
| Caddyfile only | None. Caddy reloads its config in place. |
| Icecast image (Dockerfile, `icecast.xml`, entrypoint) | Icecast restarts. All listeners and broadcasters disconnect; the desktop app reconnects by itself, players usually need a retry. |
| Icecast secrets or settings in `.env` | Same as an image change. |
| Caddy image (`caddy/Dockerfile`: Caddy or caddy-l4 version) | Caddy restarts. All connections drop for a few seconds. |

The deploy uses the Icecast and Caddy images of the last `main` commits
that changed their files (`ghcr.io/tropicast/icecast`,
`ghcr.io/tropicast/caddy`). A deploy that does not touch them keeps both
running. The bundle's `release.env` records both tags.
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
gh run watch
```

The workflow:

1. Checks that the commit is on `main` and that its Icecast image exists in
   GHCR.
2. Opens SSH to the runner's own IPv4 only: it attaches a temporary Hetzner
   firewall (`ci-deploy-<run-id>`, label `purpose=ci-deploy`) with
   `HCLOUD_TOKEN`. A final step always removes it, and the next deploy
   removes any leftover.
3. Writes `.env` on the node from GitHub secrets and variables (over SSH
   stdin, never on a command line).
4. Uploads the bundle (`deploy/compose.yaml`, `deploy/deploy.sh`,
   `caddy/Caddyfile`, `auth-stub/server.py`).
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

From GitHub, deploy an older commit of `main`:

```sh
gh workflow run deploy.yml --ref main -f ref=<older-sha>
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

## Everyday checks

```sh
ssh -i ~/.ssh/tropicast_deploy deploy@<ipv4>
/opt/tc-streaming/deploy.sh status
cd /opt/tc-streaming && docker compose logs --tail 100 icecast caddy
```

`docker compose` needs `ICECAST_IMAGE_TAG` set; take it from `CURRENT`:

```sh
export ICECAST_IMAGE_TAG=$(cut -d' ' -f2 /opt/tc-streaming/CURRENT)
```

## Incidents

### Node is down or destroyed

1. Recreate it: run the Terraform deploy workflow (plan, then apply). The
   primary IPs survive, so DNS needs no change.
2. The new server has a new host key. Update `DEPLOY_KNOWN_HOSTS` (step 2
   above) and remove the old key locally: `ssh-keygen -R <ipv4>`.
3. Run the Ansible playbook as `root` once (README, *Node hardening*).
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
- Check `docker compose logs caddy | grep -i acme`.

### Broadcasters are all rejected

Icecast denies every source when the auth endpoint is down, slow (over 15
seconds) or rejects Icecast's own credentials. Stations already live are
not affected.

- Check the Icecast log: `auth_url/url_add_client` lines show the reason.
- Check the API's health and that `ICECAST_SOURCE_AUTH_URL` and
  `ICECAST_SOURCE_AUTH_PASSWORD` match on both sides.

### Egress near the 20 TB quota

The Hetzner Console shows the server's monthly traffic (**Servers →
tc-stream-1 → Graphs/Traffic**). Above 20 TB, Hetzner bills about
$1.12/TB.

- At **70%** of the quota, or when several Starter stations are live at the
  same time, plan a second node (Growth stage in the epic).
- Lower default bitrates (Opus 48-64 kbps, #9) cut egress per listener.

### CI runner down

Jobs on `tc-runner-1` wait in the queue while it is offline. Check it with
`gh api orgs/tropicast/actions/runners --jq '.runners[] | {name, status}'`.
To deploy anyway, switch the repository back to GitHub-hosted runners
(`gh variable delete RUNS_ON`), deploy, then set it again. See
[how-to/set-up-ci-runner.md](how-to/set-up-ci-runner.md).

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
