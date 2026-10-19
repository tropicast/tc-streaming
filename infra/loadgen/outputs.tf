output "ipv4" {
  value = hcloud_server.loadgen.ipv4_address
}

output "ssh" {
  value = "ssh ops@${hcloud_server.loadgen.ipv4_address}"
}
