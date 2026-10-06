# Set up monitoring and alerts

When you finish this guide:

- You get an **email when something breaks**: the node goes down, Icecast
  stops, or the node uses 70% or 90% of its monthly traffic quota.
- You have a **dashboard** with listeners per station, traffic used this
  month, and CPU, memory and network of the node.
- Grafana checks the public URLs **from outside** every minute and warns you
  before the HTTPS certificate expires.

It uses the **Grafana Cloud free tier** (no credit card; 10,000 metric
series and 14 days of history, far more than one node needs). Plan about
45 minutes.

## How it works

```text
tc-stream-1 (Hetzner)                              Grafana Cloud
┌────────────────────────────────────┐             ┌─────────────────────┐
│ Icecast ──► icecast-exporter ──┐   │   metrics   │ Prometheus (storage)│
│                                ├─► alloy ───────►│ Alert rules ──► email│
│ host CPU/memory/disk/network ──┘   │   (HTTPS)   │ Dashboard           │
│ Hetzner API (monthly traffic) ─► icecast-exporter│ Uptime checks ──► node│
└────────────────────────────────────┘             └─────────────────────┘
```

- `icecast-exporter` reads Icecast's statistics and the node's monthly
  traffic from Hetzner.
- `alloy` (Grafana Alloy) collects those numbers plus the node's own
  CPU, memory, disk and network, and sends them to Grafana Cloud.
- Both only run when the setting `COMPOSE_PROFILES` contains `monitoring`.
  Until then nothing changes on the node.

## Before you start

- You can run the Deploy workflow (see `docs/runbook.md`).
- `gh` is logged in, and you are in the `tc-streaming` folder.
- Docker runs on your machine (step 6 uses a container to load the alert
  rules).

## Values you will collect

Write these down as you go. Treat the two tokens like passwords.

| # | Value | Example | Found in step | Stored as |
|---|---|---|---|---|
| A | Prometheus **push URL** | `https://prometheus-prod-24-prod-eu-west-2.grafana.net/api/prom/push` | 1 | GitHub variable `GRAFANA_CLOUD_PROM_URL` |
| B | Prometheus **username** (a number) | `1234567` | 1 | GitHub variable `GRAFANA_CLOUD_PROM_USER` |
| C | Token that may **send metrics** | `glc_eyJ…` | 2 | GitHub secret `GRAFANA_CLOUD_TOKEN` |
| D | Token that may **edit alert rules** | `glc_eyJ…` | 2 | only on your machine, for step 6 |
| E | Hetzner **read-only** API token | `aBc…` | 3 | GitHub secret `HCLOUD_READ_TOKEN` |

## Step 1: Create the Grafana Cloud account

Goal: get a Grafana Cloud "stack" (your own Grafana + metric storage) and
note where to send metrics.

1. Go to <https://grafana.com/auth/sign-up/create-user> and sign up for the
   free plan.
2. When asked for a stack name and region, choose a name (for example
   `tropicast`) and a **European** region.
3. Open the Cloud Portal (<https://grafana.com/orgs> → your organization).
   On your stack, find the **Prometheus** card and click **Details**
   (labels may differ slightly).
4. Copy:
   - the **Remote Write Endpoint** → value **A** (it ends in
     `/api/prom/push`);
   - the **Username / Instance ID** → value **B**.

Check: value A starts with `https://prometheus-` and ends with
`/api/prom/push`; value B is only digits.

## Step 2: Create the two Grafana tokens

Goal: one token that only sends metrics (used by the node) and one that
only edits alert rules (used by you, once).

1. In the Cloud Portal, open **Access Policies** (under *Security*).
2. Click **Create access policy**:
   - Name: `tc-stream-metrics`
   - Realm: your stack
   - Scopes: **metrics: Write** only
3. On the new policy, click **Add token**, name it `tc-stream-1`, and copy
   the token → value **C**. It is shown only once.
4. Create a second policy:
   - Name: `tc-rules`
   - Scopes: **rules: Read** and **rules: Write**
5. Add a token to it and copy it → value **D**.

Check: both tokens start with `glc_`.

## Step 3: Create the Hetzner read-only token

Goal: let the exporter read the node's monthly traffic, without being able
to change anything.

1. Open the Hetzner Console → your project → **Security** → **API tokens**
   → **Generate API token**.
2. Description: `tc-stream monitoring`. Permission: **Read**.
3. Copy the token → value **E**.

Do not reuse the *Read & Write* token used by Terraform.

## Step 4: Store the values in GitHub

Goal: the Deploy workflow writes them onto the node.

Replace the placeholders with your values A, B, C and E:

```sh
gh variable set GRAFANA_CLOUD_PROM_URL --body '<value A>'
gh variable set GRAFANA_CLOUD_PROM_USER --body '<value B>'
gh secret set GRAFANA_CLOUD_TOKEN      # paste value C when asked
gh secret set HCLOUD_READ_TOKEN        # paste value E when asked
```

Turn monitoring on. Keep `stub` in the list as long as the auth stub is in
use (until the control-plane API exists):

```sh
gh variable get COMPOSE_PROFILES             # shows the current value, e.g. "stub"
gh variable set COMPOSE_PROFILES --body 'stub,monitoring'
```

Check: `gh variable list` shows `GRAFANA_CLOUD_PROM_URL`,
`GRAFANA_CLOUD_PROM_USER` and `COMPOSE_PROFILES=stub,monitoring`;
`gh secret list` shows `GRAFANA_CLOUD_TOKEN` and `HCLOUD_READ_TOKEN`.

## Step 5: Deploy

Goal: start `icecast-exporter` and `alloy` on the node.

```sh
gh workflow run deploy.yml --ref main
gh run watch
```

Icecast and Caddy keep running; only the two monitoring containers start.

Check (after about 1 minute): in Grafana, open **Explore**, choose the
Prometheus data source (named like `grafanacloud-<stack>-prom`) and run
each query. Each must return `1`:

```text
icecast_up{instance="tc-stream-1"}
up{job="node", instance="tc-stream-1"}
hetzner_up
```

If a query returns nothing, see *Troubleshooting* below.

## Step 6: Load the alert rules

Goal: Grafana watches the metrics and raises the alerts listed in
*What the alerts mean* below.

The address is value **A without** `/push` at the end
(`…grafana.net/api/prom`). Run from the `tc-streaming` folder:

```sh
docker run --rm -v "$PWD/monitoring:/m:ro" grafana/mimirtool:3.2.1 rules load \
  --address='<value A without /push>' \
  --id='<value B>' \
  --key='<value D>' \
  /m/rules.yaml
```

Check: in Grafana, **Alerting → Alert rules** lists a group
`tropicast-streaming` with 10 rules.

Run the same command again whenever `monitoring/rules.yaml` changes.

## Step 7: Choose where alerts go

Goal: alerts reach you by email (or Telegram, Slack…).

1. In Grafana, open **Alerting → Contact points → Add contact point**.
   Name `ops-email`, integration **Email**, your address. Click **Test**
   and check that the test email arrives.
2. Open **Alerting → Notification policies** and edit the default policy:
   set its contact point to `ops-email`.
3. Optional: add a nested policy matching `severity = info` that sends to a
   quieter channel, or mute it. It only covers *station stopped
   broadcasting*, which also happens when a station goes off air on
   purpose.

Check: the test email arrived.

## Step 8: Import the dashboard

1. In Grafana, open **Dashboards → New → Import**.
2. Upload `monitoring/dashboard.json`.
3. Pick the Prometheus data source from step 5 and click **Import**.

Check: the dashboard *Tropicast streaming node* shows `Icecast up` = 1 and
your live stations.

## Step 9: Add uptime and certificate checks

Goal: Grafana probes the public URLs from outside, so you also hear about
DNS, Caddy or certificate problems.

In Grafana, open **Testing & synthetics → Synthetics → Add new check**:

1. **HTTP** check
   - URL: `https://listen.tropicastradio.com/status-json.xsl`
   - Valid status code: **404** (Caddy hides status pages; 404 means it
     works)
   - Probe locations: at least two in Europe
   - Turn on alerting, including **SSL certificate expiry** (14 days).
2. **TCP** check
   - Host: `ingest.tropicastradio.com:443`, with TLS
   - Same probes and alerting.

Check: both checks turn green within a few minutes.

## Step 10: Test one alert

Goal: prove the chain metrics → rule → email works. Do it in a quiet hour:
listeners disconnect for about two minutes.

```sh
ssh -i ~/.ssh/tropicast_deploy deploy@46.224.96.180
/opt/tc-streaming/deploy.sh compose stop icecast
# wait for the "IcecastDown" email (about 2 minutes), then:
/opt/tc-streaming/deploy.sh compose start icecast
exit
```

`deploy.sh compose …` runs `docker compose` with the active release's image
tags; plain `docker compose` on the node fails without them.

## What the alerts mean

| Alert | Severity | Fires when | First thing to do |
|---|---|---|---|
| StreamingNodeDown | critical | No metrics at all for 2 minutes | Hetzner Console: is the server running? Then `deploy.sh compose ps` on the node |
| IcecastDown | critical | Icecast does not answer for 1 minute | `deploy.sh compose logs icecast` on the node |
| IcecastExporterDown | warning | The exporter is down for 2 minutes | Station numbers are missing; streaming may still work |
| StationSourceDropped | info | A station that was live in the last 10 minutes is off air | Expected if it stopped on purpose |
| EgressQuota70Percent | warning | 70% of the monthly traffic quota is used | Plan a second node or lower bitrates |
| EgressQuota90Percent | critical | 90% is used | Above 100%, Hetzner bills about $1.12/TB |
| HetznerTrafficUnknown | warning | The Hetzner API cannot be read for 30 minutes | Check `HCLOUD_READ_TOKEN` |
| NodeDiskAlmostFull | warning | A disk is over 85% full for 10 minutes | Free space (`docker system prune`) |
| NodeMemoryLow | warning | Under 10% memory free for 10 minutes | Check which container uses it |
| NodeCpuBusy | warning | CPU over 90% for 15 minutes | Check listener count; plan capacity |

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| No metrics in Explore at all | Monitoring not deployed, or wrong URL/user/token | `COMPOSE_PROFILES` must contain `monitoring`; on the node run `/opt/tc-streaming/deploy.sh compose logs alloy` and look for `401` or `404` |
| `401` in the alloy logs | Token C wrong or without `metrics: Write` | Create a new token (step 2), update `GRAFANA_CLOUD_TOKEN`, deploy |
| `404` in the alloy logs | Value A incomplete | It must end in `/api/prom/push` |
| `icecast_up` is `0` | Exporter cannot read Icecast's statistics | Usually a wrong admin password after a secret change: deploy again |
| `hetzner_up` is `0` | Token E wrong or not set | Check `HCLOUD_READ_TOKEN`, deploy |
| `rules load` returns `401` | Token D wrong or without `rules: Write` | Create a new token for `tc-rules` |
| Rules loaded but no email | No contact point on the notification policy | Step 7 |

## For later

- **Control plane**: the API can read live listeners and station status
  from Grafana Cloud with a token that has `metrics: Read`, for example the
  query `sum by (station) (icecast_mount_listeners)`.
- **Local test**: `tests/monitoring.sh` runs the exporter and Alloy against
  a local Prometheus; CI runs it with the e2e tests.
- **Changing rules**: edit `monitoring/rules.yaml`, test with
  `docker run --rm -v "$PWD/monitoring:/m:ro" -w /m --entrypoint promtool prom/prometheus:v3.15.0 test rules rules.test.yaml`,
  then repeat step 6.
