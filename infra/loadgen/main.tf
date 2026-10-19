# Throwaway load generator for the load and soak tests (#96,
# docs/load-test.md): sources and listeners in the node's location, so the
# network between them is not the bottleneck. Create it for a test and
# destroy it after: it is billed while it exists.

terraform {
  required_version = ">= 1.10"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.54"
    }
  }

  # Local state on purpose: nothing here outlives a test, and it never
  # shares state with the streaming node (infra/terraform).
}

# Reads the API token from the HCLOUD_TOKEN environment variable.
provider "hcloud" {}

locals {
  labels = {
    project = "tropicast"
    role    = "loadgen"
    node    = var.name
  }
}

resource "hcloud_ssh_key" "admin" {
  for_each   = var.ssh_public_keys
  name       = "${var.name}-${each.key}"
  public_key = each.value
  labels     = local.labels
}

# SSH from admins only. It only connects out: to the listen and ingest hosts.
resource "hcloud_firewall" "loadgen" {
  name   = "${var.name}-fw"
  labels = local.labels

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

resource "hcloud_server" "loadgen" {
  name         = var.name
  server_type  = var.server_type
  image        = var.image
  location     = var.location
  ssh_keys     = [for key in hcloud_ssh_key.admin : key.id]
  firewall_ids = [hcloud_firewall.loadgen.id]
  labels       = local.labels
  user_data = templatefile("${path.module}/cloud-init.yaml", {
    repository = var.repository
    ref        = var.ref
    # A JSON list is a YAML flow sequence.
    ssh_keys = jsonencode(values(var.ssh_public_keys))
  })

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }
}
