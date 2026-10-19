# Infrastructure and operations

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
[docs/how-to/provision-hetzner-with-ci.md](../how-to/provision-hetzner-with-ci.md).

`backend.hcl`, `terraform.tfvars` and state files are git-ignored. Delete
protection must be turned off in `main.tf` before `terraform destroy` can
remove the server or IPs.

## Load generator (Terraform)

`infra/loadgen` creates a throwaway server for the load and soak tests
(#96, [docs/load-test.md](../load-test.md#re-test-after-the-latency-changes-83)):
a CX33 in the node's location, SSH from `admin_cidrs` only, and nothing else
inbound. You log in as `ops` (passwordless sudo, your `ssh_public_keys`);
root cannot log in. cloud-init installs ffmpeg, Go and tmux, clones this repository to
`/opt/tc-streaming` and builds `/usr/local/bin/loadtest`. Its state is local
and separate from the node's. It is billed by the hour while it exists
(about $0.02/h for a CX33), so destroy it when the test ends. Changing `cloud-init.yaml` or the keys
replaces the server on the next `apply`.

```sh
cd infra/loadgen
cp terraform.tfvars.example terraform.tfvars  # keys, admin CIDRs
export HCLOUD_TOKEN=...
terraform init
terraform apply                               # prints the ssh command
ssh ops@<ipv4> cloud-init status --wait      # ready when it says "done"
terraform destroy                             # after the test
```

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

[docs/runbook.md](../runbook.md) covers first-time setup, deploys,
rollbacks, what restarts what, and incidents.

## Monitoring

`exporter/icecast_exporter.py` (station listeners and bytes, Hetzner
monthly traffic) and Grafana Alloy (`deploy/alloy/config.alloy`) run on the
node with the Compose profile `monitoring` and push to Grafana Cloud.
Alloy also ships Icecast's logs to Grafana Cloud Logs (#46), reading them
through `docker-socket-proxy`, which only lets through the read calls log
collection needs. The host's `/run` (with `docker.sock`) is hidden from
Alloy, so it cannot go around the proxy.
Alert rules (`monitoring/rules.yaml`, unit-tested with
`monitoring/rules.test.yaml`) and a dashboard (`monitoring/dashboard.json`)
are loaded there. See
[docs/how-to/set-up-monitoring.md](../how-to/set-up-monitoring.md)
(issue #10).
