output "admins_group_id" {
  value = netbird_group.admins.id
}

output "management_vm_group_id" {
  value = netbird_group.management_vm.id
}

output "k8s_routers_group_id" {
  value = netbird_group.k8s_routers.id
}

output "proxy_group_id" {
  value = netbird_group.proxy.id
}

output "adguard_dns_group_id" {
  value       = netbird_group.adguard_dns.id
  description = "NetBird group ID for peers that should receive AdGuard DNS"
}

output "traefik_resource_id" {
  value = netbird_network_resource.traefik.id
}

output "k8s_setup_key" {
  value     = netbird_setup_key.k8s_routers.key
  sensitive = true
}

output "management_vm_setup_key" {
  value     = netbird_setup_key.management_vm.key
  sensitive = true
}

output "proxy_setup_key" {
  value     = netbird_setup_key.proxy.key
  sensitive = true
}
