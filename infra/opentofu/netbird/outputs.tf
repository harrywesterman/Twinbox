output "server_name" {
  value = hcloud_server.netbird.name
}

output "server_ipv4" {
  value = hcloud_server.netbird.ipv4_address
}

output "netbird_url" {
  value = "https://${var.netbird_fqdn}"
}

output "netbird_proxy_domain" {
  value = var.netbird_proxy_domain
}
