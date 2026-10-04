# Provision the Hetzner node for the first time with CI

This guide creates the MVP streaming node (issue #3) from GitHub Actions,
using the **Terraform deploy** workflow
(`.github/workflows/terraform-deploy.yml`). You do it once per
environment. Later changes use the same workflow.

You run the workflow twice:

1. **plan**: Terraform shows what it will create in the run summary and
   saves the plan.
2. **apply**: you pass the plan run's ID, and the workflow applies exactly
   that saved plan. Terraform refuses it if the state changed in between.

The repository is private on GitHub's free plan, which has no environment
approvals for private repositories. The review step is therefore you
reading the plan before starting the apply run. Only people with write
access can start the workflow, and it only runs from `main`.

What it creates in Hetzner Cloud:

| Resource | Count |
|---|---|
| CX33 server (`fsn1`, Debian 12) | 1 |
| Primary IPs (IPv4 + IPv6) | 2 |
| Firewall (22 from admin CIDRs, 80/443 public) | 1 |
| SSH keys | one per key in `ssh_public_keys` |
| DNS records `listen` / `ingest` (A + AAAA) | 4, only if `dns_zone` is set |

Expect about $10-14/month for the CX33 plus the primary IPv4 charge. Check
current Hetzner prices first.

## Before you start

You need:

- Owner or admin access to the `tropicast/tc-streaming` GitHub repository.
- A Hetzner account that can create Cloud projects and Object Storage.
- `gh` (GitHub CLI) logged in, and `ssh-keygen`, on your machine.
- `dig` and `nc` for the checks. On Arch/Omarchy:
  `omarchy pkg add bind openbsd-netcat` (or
  `sudo pacman -S bind openbsd-netcat`). On Debian/Ubuntu:
  `sudo apt install dnsutils netcat-openbsd`.

## 1. Create the Hetzner Cloud project

1. In the [Hetzner Console](https://console.hetzner.com/), create a project,
   for example `tropicast-production`.
2. Open the project, then **Security → API tokens → Generate API token**.
   Choose **Read & Write**. Copy the token; Hetzner shows it only once.

The token can change everything in this project. Store it only in GitHub
secrets (step 5) or a password manager.

## 2. Create the Terraform state bucket

Terraform keeps its state in Hetzner Object Storage (S3-compatible).

1. In the same project, open **Object Storage → Create bucket**.
   - Location: `fsn1` (same as the server).
   - Name: unique, for example `tropicast-tfstate`.
   - Visibility: **private**.
2. Open **Security → S3 credentials → Generate credentials**. Copy the
   access key and the secret key.
3. Recommended: turn on versioning, so you can recover an older state.
   With the AWS CLI:

   ```sh
   aws s3api put-bucket-versioning \
     --endpoint-url https://fsn1.your-objectstorage.com \
     --bucket tropicast-tfstate \
     --versioning-configuration Status=Enabled
   ```

The bucket has no state locking. The workflow allows only one run at a
time, so never run `terraform apply` from a laptop while it is running.

## 3. Optional: DNS zone

To let Terraform create `listen.<domain>` and `ingest.<domain>`:

1. Check that you control the domain: you can log in at its registrar and
   change its name servers. `whois <domain>` shows the registrar and the
   current name servers.
2. In the same project, open **DNS → Add zone** and add your domain.
3. Before switching, copy any records the domain still needs (website,
   email) into the Hetzner zone. Once the name servers change, only the
   Hetzner zone answers.
4. At your domain registrar, replace the name servers with the ones Hetzner
   lists for the zone (for example `hydrogen.ns.hetzner.com`,
   `oxygen.ns.hetzner.com` and `helium.ns.hetzner.de`).
5. Check the delegation. It can take from a few minutes to 48 hours:

   ```sh
   dig +short NS <domain> @1.1.1.1   # must list the Hetzner name servers
   ```

   Until it does, the Hetzner Console shows **Invalid zone delegation**.
   That does not block `terraform apply`; the records exist in the zone
   but nobody can resolve them yet.

Skip this to manage DNS elsewhere. Then leave `dns_zone = null` and point
the records at the IPs from the workflow output by hand.

## 4. Prepare the Terraform variables

1. Create an admin SSH key if you do not have one:

   ```sh
   ssh-keygen -t ed25519 -C "tropicast-admin" -f ~/.ssh/tropicast_admin
   ```

2. Find the public IP you will SSH from (`curl -4 https://ifconfig.me`).
3. Write `terraform.tfvars` from `infra/terraform/terraform.tfvars.example`:

   ```hcl
   name        = "tc-stream-1"
   location    = "fsn1"
   server_type = "cx33"

   ssh_public_keys = {
     admin = "ssh-ed25519 AAAA... tropicast-admin"
   }

   admin_cidrs = ["198.51.100.23/32"]

   dns_zone = "example.com" # or null
   ```

These values are not secret, but they reveal your admin IP. They are
stored as a repository variable, visible to anyone with write access.

## 5. Configure GitHub

Run these from the repository folder.

Secrets:

```sh
gh secret set HCLOUD_TOKEN          # Hetzner API token (step 1)
gh secret set TF_STATE_ACCESS_KEY   # S3 access key (step 2)
gh secret set TF_STATE_SECRET_KEY   # S3 secret key (step 2)
```

Variables:

```sh
gh variable set TFVARS < terraform.tfvars
gh variable set TF_STATE_BUCKET --body tropicast-tfstate
gh variable set TF_STATE_LOCATION --body fsn1
```

These are repository-level secrets, so any workflow on `main` could read
them. Review workflow changes in pull requests with that in mind.

Delete your local `terraform.tfvars` copy afterwards if you do not need it.

## 6. Run a plan

```sh
gh workflow run terraform-deploy.yml --ref main -f action=plan
gh run list --workflow terraform-deploy.yml --limit 1   # note the run ID
gh run watch <plan-run-id>
```

Or in GitHub: **Actions → Terraform deploy → Run workflow**, with
*action* = `plan`. The run ID is the number at the end of the run's URL.

Open the run summary and check the plan. For a first run it should only
**add** resources: 1 server, 2 primary IPs, 1 firewall, your SSH keys and,
with a DNS zone, 4 records. Nothing should be changed or destroyed.

## 7. Apply

Apply the plan you reviewed, within 3 days (the saved plan then expires):

```sh
gh workflow run terraform-deploy.yml --ref main \
  -f action=apply -f plan_run_id=<plan-run-id>
gh run watch
```

When it finishes, the run summary lists `ipv4`, `ipv6`, `server_id` and
`hostnames`.

## 8. Check the node

Run these from your own machine, **not on the node**. Traffic the node
sends to its own address skips the Hetzner firewall, so a check on the node
proves nothing.

```sh
ssh -i ~/.ssh/tropicast_admin root@<ipv4>   # connects (you are in admin_cidrs)
nc -zv -w 3 <ipv4> 8000                     # must time out
```

| `nc` result for port 8000 | Meaning |
|---|---|
| `timed out` | Correct: the firewall drops the connection. |
| `Connection refused` | The packet reached the node: the firewall is not applied, or you ran the check on the node. |
| `succeeded` | Port 8000 is open to the internet. Stop and fix the firewall. |

If you set `dns_zone`, check DNS through a public resolver:

```sh
dig +short NS <domain> @1.1.1.1            # the Hetzner name servers
dig +short listen.<domain> @1.1.1.1        # <ipv4>
dig +short AAAA listen.<domain> @1.1.1.1   # <ipv6>
```

If `dig` prints nothing, look at the full answer:

```sh
dig NS <domain> @1.1.1.1
dig NS <domain> @a.gtld-servers.net +norec  # what the .com registry delegates to
```

- `status: SERVFAIL` with `EDE: 22 (No Reachable Authority)`, or the
  registry still listing the old name servers: the registrar change
  (section 3, step 4) is not done or not live yet.
- The registry lists the Hetzner name servers but `listen.<domain>` is
  empty: wait for caches to expire (up to 48 hours), or check the records
  in **DNS → your zone**.

## Next steps

1. Harden the node and install Docker with Ansible
   (README, *Node hardening*). Run it as `root` once; it then turns off
   root login.
2. Deploy the Icecast and Caddy stack (issue #11).

## Troubleshooting

| Error | Fix |
|---|---|
| `Set the TFVARS repository variable` | Step 5 variables are missing. |
| `NoSuchBucket` or `403` during `terraform init` | Check the bucket name, location and S3 credentials. |
| `server type cx33 not available` / `resource_unavailable` | Hetzner is out of capacity in that location. Set `location` to `nbg1` or `hel1` in `TFVARS`. |
| `Saved plan is stale` | The state changed after the plan. Run a new plan and apply that one. |
| `Unable to download artifact` | The plan run ID is wrong, or the plan is older than 3 days. Run a new plan. |
| `Run this workflow from main.` | Start it with `--ref main`. |
| `zone not found` | The DNS zone is in another project, or `dns_zone` is misspelled. |
| `delete protection` errors on destroy | Intended. Turn protection off in `main.tf` in a reviewed PR first. |
| Hetzner Console: **Invalid zone delegation** | The registrar still points the domain at other name servers. See section 3. |
| `dig` on the node: `communications error ... timed out` | The node's resolver is waiting on a broken delegation. Fix the delegation; test from your machine with `@1.1.1.1`. |

## Changing the node later

Edit `infra/terraform` in a pull request; the **Terraform** workflow checks
it. After merging, run **Terraform deploy** with `plan`, review it, then
`apply` that run ID. To change
variables, update the `TFVARS` repository variable first.
