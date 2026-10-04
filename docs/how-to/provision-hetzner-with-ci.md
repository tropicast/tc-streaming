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

1. In the same project, open **DNS → Add zone** and add your domain.
2. At your domain registrar, set the name servers to the ones Hetzner
   lists for the zone.

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

```sh
ssh -i ~/.ssh/tropicast_admin root@<ipv4>   # works from an admin CIDR
nc -zv -w 3 <ipv4> 8000                     # must fail: Icecast port closed
dig +short listen.<domain>                  # returns <ipv4> (if DNS is set)
```

DNS can take a few minutes after the name server change.

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

## Changing the node later

Edit `infra/terraform` in a pull request; the **Terraform** workflow checks
it. After merging, run **Terraform deploy** with `plan`, review it, then
`apply` that run ID. To change
variables, update the `TFVARS` repository variable first.
