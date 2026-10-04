output "server_id" {
  value = hcloud_server.streaming.id
}

output "ipv4" {
  value = hcloud_primary_ip.ipv4.ip_address
}

output "ipv6" {
  value = hcloud_primary_ip.ipv6.ip_address
}

output "hostnames" {
  value = var.dns_zone == null ? [] : [
    "${var.listen_hostname}.${var.dns_zone}",
    "${var.ingest_hostname}.${var.dns_zone}",
  ]
}
