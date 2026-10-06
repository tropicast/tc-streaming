output "server_id" {
  value = hcloud_server.streaming.id
}

output "ipv4" {
  value = hcloud_primary_ip.ipv4.ip_address
}

# The server's IPv6 address (::1 of its /64), for AAAA records.
output "ipv6" {
  value = hcloud_server.streaming.ipv6_address
}

output "ipv6_network" {
  value = hcloud_server.streaming.ipv6_network
}

output "hostnames" {
  value = var.dns_zone == null ? [] : [
    "${var.listen_hostname}.${var.dns_zone}",
    "${var.ingest_hostname}.${var.dns_zone}",
  ]
}

output "runner_ipv4" {
  value = hcloud_server.runner.ipv4_address
}
