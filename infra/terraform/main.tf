locals {
  labels = {
    project = "tropicast"
    role    = "icecast-origin"
    node    = var.name
  }
}

resource "hcloud_ssh_key" "admin" {
  for_each   = var.ssh_public_keys
  name       = "${var.name}-${each.key}"
  public_key = each.value
  labels     = local.labels
}

# Primary IPs outlive the server, so a replacement node keeps the same
# addresses and DNS does not change.
resource "hcloud_primary_ip" "ipv4" {
  name              = "${var.name}-ipv4"
  type              = "ipv4"
  location          = var.location
  auto_delete       = false
  delete_protection = true
  labels            = local.labels
}

resource "hcloud_primary_ip" "ipv6" {
  name              = "${var.name}-ipv6"
  type              = "ipv6"
  location          = var.location
  auto_delete       = false
  delete_protection = true
  labels            = local.labels
}

# Only SSH (admin CIDRs), HTTP and HTTPS are reachable. Icecast's port 8000
# stays closed; Caddy is the only public entry point.
resource "hcloud_firewall" "streaming" {
  name   = "${var.name}-fw"
  labels = local.labels

  # The CI runner deploys over SSH as the deploy user.
  rule {
    description = "SSH from admins and the CI runner"
    direction   = "in"
    protocol    = "tcp"
    port        = "22"
    source_ips  = concat(var.admin_cidrs, ["${hcloud_server.runner.ipv4_address}/32"])
  }

  rule {
    description = "HTTP (ACME and redirect to HTTPS)"
    direction   = "in"
    protocol    = "tcp"
    port        = "80"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }

  rule {
    description = "HTTPS listeners and ingest"
    direction   = "in"
    protocol    = "tcp"
    port        = "443"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }

  rule {
    description = "HTTP/3"
    direction   = "in"
    protocol    = "udp"
    port        = "443"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }

  rule {
    description = "ICMP for path MTU discovery and diagnostics"
    direction   = "in"
    protocol    = "icmp"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }
}

resource "hcloud_server" "streaming" {
  name               = var.name
  server_type        = var.server_type
  image              = var.image
  location           = var.location
  ssh_keys           = [for key in hcloud_ssh_key.admin : key.id]
  firewall_ids       = [hcloud_firewall.streaming.id]
  delete_protection  = true
  rebuild_protection = true
  labels             = local.labels
  user_data          = file("${path.module}/cloud-init.yaml")

  public_net {
    ipv4_enabled = true
    ipv4         = hcloud_primary_ip.ipv4.id
    ipv6_enabled = true
    ipv6         = hcloud_primary_ip.ipv6.id
  }

  # Host setup is owned by the configuration step (#4); do not rebuild the
  # node when the base image or bootstrap file changes.
  lifecycle {
    ignore_changes = [image, user_data, ssh_keys]
  }
}

data "hcloud_zone" "main" {
  count = var.dns_zone == null ? 0 : 1
  name  = var.dns_zone
}

locals {
  dns_records = var.dns_zone == null ? {} : {
    for pair in setproduct([var.listen_hostname, var.ingest_hostname], ["A", "AAAA"]) :
    "${pair[0]}-${pair[1]}" => { name = pair[0], type = pair[1] }
  }
}

resource "hcloud_zone_rrset" "streaming" {
  for_each = local.dns_records
  zone     = data.hcloud_zone.main[0].name
  name     = each.value.name
  type     = each.value.type
  ttl      = var.dns_ttl
  labels   = local.labels

  records = [{
    # The IPv6 primary IP is a /64 network; the server answers on its ::1.
    value = each.value.type == "A" ? hcloud_primary_ip.ipv4.ip_address : hcloud_server.streaming.ipv6_address
  }]
}
