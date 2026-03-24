output "server_name" {
  value = hcloud_server.wiredoor.name
}

output "server_ipv4" {
  value = hcloud_server.wiredoor.ipv4_address
}

output "wiredoor_url" {
  value = "https://${var.wiredoor_fqdn}"
}
