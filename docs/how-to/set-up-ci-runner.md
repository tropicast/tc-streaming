# Set up the self-hosted CI runner

This guide creates a self-hosted GitHub Actions runner host for the
`tropicast` organization on a Hetzner CX33 (4 vCPU, 8 GB RAM, about
$10-14/month plus the IPv4 charge). It runs two runner processes,
`tc-runner-1` and `tc-runner-1-2`, so two jobs run at the same time.

Jobs on a self-hosted runner do not use GitHub-hosted minutes. GitHub
announced a platform fee of $0.002 per minute for self-hosted runners on
private repositories, then postponed it; check GitHub's billing docs.

The runner serves every **private** repository in the organization. Each
repository opts in with its `RUNS_ON` variable (step 6).

## What gets created

| Piece | Where |
|---|---|
| Server `tc-runner-1` (CX33, `fsn1`, Debian 12) and its firewall (SSH from `admin_cidrs` only, no other inbound) | `infra/terraform/runner.tf` |
| The runner's IPv4 added to the streaming node's SSH rule, so deploys reach the node directly | `infra/terraform/main.tf` |
| Host baseline (same as the node: `ops` user, SSH hardening, fail2ban, updates without reboot, Docker) | `infra/ansible/tasks/baseline.yml` |
| CI tools, the `runner` user, a weekly Docker cleanup | `infra/ansible/runner.yml` |
| One runner process per entry in `runner_instances` (directory, registration, systemd service) | `infra/ansible/tasks/runner-instance.yml` |

The `runner` user is in the `docker` group and has passwordless sudo, like
GitHub's own runners. Docker access is root-equivalent anyway, so keep this
VM for CI only.

## Before you start

- If GitHub refuses jobs because of a **failed payment**, fix that first:
  GitHub may refuse jobs on self-hosted runners too.
- You need org owner rights, the Terraform state credentials and the
  Hetzner token on your machine, and `uv` (for Ansible).

## 1. Create the server with Terraform

CI may be blocked, so run Terraform from your machine:

```sh
cd infra/terraform
gh variable get TFVARS > terraform.tfvars   # same variables as CI
cp backend.hcl.example backend.hcl          # set bucket and location
export HCLOUD_TOKEN=...                      # Hetzner project token
export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...  # state bucket keys
terraform init -backend-config=backend.hcl
terraform plan
```

The plan must show only:

- **create** `hcloud_firewall.runner` and `hcloud_server.runner`;
- **update in place** `hcloud_firewall.streaming` (SSH rule gains the
  runner's `/32`).

Nothing may be destroyed or replaced. Then:

```sh
terraform apply
terraform output runner_ipv4
```

Delete the local `terraform.tfvars` afterwards if you do not need it.

## 2. Inventory and variables

In `infra/ansible/inventory.ini` (see `inventory.example.ini`):

```ini
[runners]
tc-runner-1 ansible_host=<runner_ipv4> ansible_user=root ansible_ssh_private_key_file=~/.ssh/tropicast_admin
```

`ops_ssh_keys` must be visible to the runner too. Move it from
`group_vars/streaming.yml` to `group_vars/all.yml` (see
`group_vars_example.yml`).

## 3. Register and install the runner

A registration token needs the `admin:org` scope and expires after one
hour:

```sh
gh auth refresh -h github.com -s admin:org
cd infra/ansible
token=$(gh api -X POST orgs/tropicast/actions/runners/registration-token --jq .token)
uvx --from ansible ansible-playbook runner.yml -l runners -e runner_registration_token="$token"
unset token
```

The first run disables root login. Set `ansible_user=ops` for the runner
in `inventory.ini`. Later runs need no token: registration is skipped once
done.

Check:

```sh
gh api orgs/tropicast/actions/runners --jq '.runners[] | {name, status, labels: [.labels[].name]}'
```

`tc-runner-1` and `tc-runner-1-2` must be `online`, with labels
`self-hosted`, `Linux`, `X64`, `hetzner`, `fsn1`.

## 4. Organization settings

In **Organization settings → Actions**:

- **Runner groups → Default**: keep *Allow public repositories* **off**.
  Only private repositories may use the runner.
- **General → Fork pull request workflows**: keep running workflows from
  fork pull requests **off**.

## 5. Check the node rule

After the Terraform apply, the streaming node accepts SSH from the runner.
The Deploy workflow still opens and closes its temporary firewall
(`deploy/ci-ssh-access.sh`); on the runner this is harmless, and it keeps
deploys working on GitHub-hosted runners.

## 6. Switch a repository to the runner

```sh
gh variable set RUNS_ON --repo tropicast/tc-streaming --body '["self-hosted","linux","x64"]'
```

Every tc-streaming workflow reads `RUNS_ON`. To fall back to GitHub-hosted
runners (runner down, maintenance):

```sh
gh variable delete RUNS_ON --repo tropicast/tc-streaming
```

Other repositories adopt it the same way: set
`runs-on: ${{ fromJSON(vars.RUNS_ON || '"ubuntu-latest"') }}` on their
Linux jobs. Windows and macOS jobs (tc-station) stay on hosted runners.

Each runner process runs one job at a time, so the host runs two jobs in
parallel; further jobs wait in the queue. Both processes share the Docker
daemon and its build cache. Workflows stay parallel-safe by keeping
per-run names: image tags (`…:ci-<run>`, `…:e2e-<run>`), Compose projects
and free ports in `tests/*.sh`, and a per-job `DOCKER_CONFIG` and Trivy
cache under `$RUNNER_TEMP`. Follow the same rules in new workflows.

To add a process, append it to `runner_instances` in `runner.yml` and run
the playbook again with a new registration token. Registered processes are
skipped.

## Operating the runner

- **Updates**: the runner updates itself. Debian security updates install
  automatically; reboot by hand when `/var/run/reboot-required` exists (no
  listeners are affected, but a running job fails).
- **Disk**: a weekly timer (`docker-cleanup.timer`) prunes images older
  than 7 days and trims the build cache to 20 GB.
- **Logs**: `ssh ops@<runner_ipv4>`, then
  `journalctl -u 'actions.runner.*' -f` (both processes).
- **Remove or rotate**: on the runner,
  `sudo -u runner /opt/actions-runner/config.sh remove --token <removal-token>`
  (token from `gh api -X POST orgs/tropicast/actions/runners/remove-token --jq .token`),
  then delete `/opt/actions-runner/.runner` and run `runner.yml` again with
  a new registration token. The second process lives in
  `/opt/actions-runner-2`.
- **Secrets**: jobs must not leave credentials in the runner's home. The
  Deploy workflow removes its SSH key and registry login at the end.
