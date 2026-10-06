# Set up monitoring and alerts

This guide connects the streaming node to **Grafana Cloud** (free tier)
for metrics, alerts, a dashboard and external uptime checks (issue #10).

## What runs where

| Piece | Where | Does |
|---|---|---|
| `icecast-exporter` | node, Compose profile `monitoring` | Reads Icecast's admin stats (listeners and bytes per station) and the node's monthly traffic from the Hetzner API. Serves `/metrics` on the internal Docker network only. |
| `alloy` (Grafana Alloy) | node, Compose profile `monitoring` | Collects host metrics and the exporter's metrics, pushes them to Grafana Cloud. |
| Alert rules | Grafana Cloud (`monitoring/rules.yaml`) | Node down, Icecast down, egress at 70% and 90% of the quota, a station dropping, disk, memory, CPU. |
| Dashboard | Grafana Cloud (`monitoring/dashboard.json`) | Listeners per station, egress vs quota, host load. |
| Uptime checks | Grafana Cloud Synthetic Monitoring | HTTPS reachability from outside and certificate expiry. |

Without the `monitoring` profile, nothing changes on the node.

## 1. Grafana Cloud stack

1. Sign up at <https://grafana.com/products/cloud/> (free tier) and create a
   stack in an EU region.
2. In the Cloud Portal, open your stack → **Prometheus → Details**. Note:
   - the **remote write URL** (ends in `/api/prom/push`);
   - the **username / instance ID** (a number).
3. **Access Policies → Create access policy** `tc-stream-metrics` with
   scope `metrics:write`, then **Add token**. Copy the token.
4. Create a second policy `tc-rules` with scopes `rules:read` and
   `rules:write`, and a token for it. You only need it on your machine
   (step 5).

## 2. Hetzner read-only token

In the Hetzner Console, project → **Security → API tokens → Generate API
token**, permission **Read**. The exporter uses it to read the node's
monthly traffic. Do not reuse the Read & Write token.

## 3. GitHub secrets and variables

```sh
gh secret set GRAFANA_CLOUD_TOKEN      # metrics:write token (step 1.3)
gh secret set HCLOUD_READ_TOKEN        # read-only Hetzner token (step 2)
gh variable set GRAFANA_CLOUD_PROM_URL --body https://prometheus-prod-XX-prod-eu-west-X.grafana.net/api/prom/push
gh variable set GRAFANA_CLOUD_PROM_USER --body <instance-id>
gh variable set COMPOSE_PROFILES --body stub,monitoring   # keep "stub" until the API exists
```

The Deploy workflow writes them into the node's `.env`. `NODE_NAME` comes
from the `DEPLOY_SERVER` variable (default `tc-stream-1`) and becomes the
`instance` label.

## 4. Deploy

```sh
gh workflow run deploy.yml --ref main
gh run watch
```

Only `icecast-exporter` and `alloy` start; Icecast and Caddy keep running.
Within a minute, **Explore** in Grafana shows `icecast_up` and
`up{job="node"}` for `instance="tc-stream-1"`.

## 5. Alert rules

Load the rules with `mimirtool`, using the `tc-rules` token. The address is
the remote write URL without `/api/prom/push`:

```sh
docker run --rm -v "$PWD/monitoring:/m:ro" grafana/mimirtool:3.2.1 rules load \
  --address=https://prometheus-prod-XX-prod-eu-west-X.grafana.net/api/prom \
  --id=<instance-id> --key=<tc-rules-token> /m/rules.yaml
```

Run it again after changing `monitoring/rules.yaml`. Test changes first
with `promtool` (CI does this):

```sh
docker run --rm -v "$PWD/monitoring:/m:ro" -w /m --entrypoint promtool \
  prom/prometheus:v3.15.0 test rules rules.test.yaml
```

## 6. Where alerts go

In Grafana: **Alerting → Contact points → Add contact point** (email,
Telegram, …). Then **Alerting → Notification policies**: route
`severity=critical` and `severity=warning` to it; send `severity=info`
(`StationSourceDropped`) to a quieter channel or mute it.

## 7. Dashboard

**Dashboards → New → Import**, upload `monitoring/dashboard.json`, and pick
the stack's Prometheus data source.

## 8. Uptime and certificate checks

**Testing & synthetics → Synthetics → Add new check → HTTP**, from two or
more probe locations in Europe:

| Check | URL | Valid status |
|---|---|---|
| Listen host | `https://listen.<domain>/status-json.xsl` | 404 |
| Ingest host | `https://ingest.<domain>/` (TCP check on port 443) | connects |

Turn on alerting for the checks and for **SSL certificate expiry** (warn at
14 days). A `404` is the expected answer: Caddy hides status pages.

## Check the alerts work

On the node, stop Icecast for two minutes in a quiet hour (listeners
disconnect):

```sh
ssh -i ~/.ssh/tropicast_deploy deploy@<ipv4>
cd /opt/tc-streaming
export ICECAST_IMAGE_TAG=$(cut -d' ' -f2 CURRENT) CADDY_IMAGE_TAG=$(sed -n 's/^CADDY_IMAGE_TAG=//p' releases/$(cut -d' ' -f1 CURRENT)/release.env)
docker compose --env-file .env stop icecast   # IcecastDown fires within 2 minutes
docker compose --env-file .env start icecast
```

## Listener counts for the control plane

The API can read live listeners and station status from Grafana Cloud's
Prometheus query API, for example
`sum by (station) (icecast_mount_listeners)` and `icecast_mount_up`, with a
`metrics:read` token. Nothing on the node is exposed for this.

## Local test

`tests/monitoring.sh` runs the exporter and Alloy against a local
Prometheus and checks station, host and down metrics end to end. CI runs it
with the e2e tests.
