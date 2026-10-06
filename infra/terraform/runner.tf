# Self-hosted GitHub Actions runner for the tropicast organization.
# Setup: docs/how-to/set-up-ci-runner.md

resource "hcloud_firewall" "runner" {
  name = "${var.runner_name}-fw"
  labels = {
    project = "tropicast"
    role    = "ci-runner"
  }

  # The runner only makes outbound connections (it polls GitHub), so the
  # only inbound traffic is admin SSH.
  rule {
    description = "SSH from admins"
    direction   = "in"
    protocol    = "tcp"
    port        = "22"
    source_ips  = var.admin_cidrs
  }

  rule {
    description = "ICMP for path MTU discovery and diagnostics"
    direction   = "in"
    protocol    = "icmp"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }
}

resource "hcloud_server" "runner" {
  name               = var.runner_name
  server_type        = var.runner_server_type
  image              = var.image
  location           = var.location
  ssh_keys           = [for key in hcloud_ssh_key.admin : key.id]
  firewall_ids       = [hcloud_firewall.runner.id]
  delete_protection  = true
  rebuild_protection = true
  user_data          = file("${path.module}/cloud-init.yaml")
  labels = {
    project = "tropicast"
    role    = "ci-runner"
    node    = var.runner_name
  }

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  # Host setup is owned by infra/ansible/runner.yml.
  lifecycle {
    ignore_changes = [image, user_data, ssh_keys]
  }
}
