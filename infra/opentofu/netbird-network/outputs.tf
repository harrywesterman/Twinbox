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

output "management_lan_routers_group_id" {
  value       = netbird_group.management_lan_routers.id
  description = "NetBird group ID for Management VM LAN routing peers"
}

output "bastion_exit_routers_group_id" {
  value       = netbird_group.bastion_exit_routers.id
  description = "NetBird group ID for Hetzner internet exit routing peers"
}

output "mailu_relay_egress_group_id" {
  value       = netbird_group.mailu_relay_egress.id
  description = "NetBird group ID for Mailu relay egress peers"
}

output "exit_node_users_group_id" {
  value       = netbird_group.exit_node_users.id
  description = "NetBird group ID for peers allowed to opt into Twinbox routes"
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

output "management_lan_router_setup_key" {
  value     = netbird_setup_key.management_lan_router.key
  sensitive = true
}

output "proxy_setup_key" {
  value     = netbird_setup_key.proxy.key
  sensitive = true
}

output "bastion_exit_router_setup_key" {
  value     = netbird_setup_key.bastion_exit_router.key
  sensitive = true
}

output "mailu_relay_egress_setup_key" {
  value     = netbird_setup_key.mailu_relay_egress.key
  sensitive = true
}
