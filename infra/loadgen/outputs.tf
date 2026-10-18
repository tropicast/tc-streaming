output "ipv4" {
  value = hcloud_server.loadgen.ipv4_address
}

output "ssh" {
  value = "ssh root@${hcloud_server.loadgen.ipv4_address}"
}
