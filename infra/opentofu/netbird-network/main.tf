locals {
  name_prefix = "twinbox-${var.cluster_id}"

  traefik_resource_is_host = length(regexall("^([0-9]{1,3}\\.){3}[0-9]{1,3}(/32)?$", var.traefik_resource_address)) > 0
  traefik_resource_type    = local.traefik_resource_is_host ? "host" : "domain"
}

data "netbird_group" "all" {
  name = "All"
}

resource "netbird_group" "admins" {
  name = "${local.name_prefix}-admins"
}

resource "netbird_group" "management_vm" {
  name = "${local.name_prefix}-management-vm"
}

resource "netbird_group" "k8s_routers" {
  name = "${local.name_prefix}-k8s-routers"
}

resource "netbird_group" "proxy" {
  name = "${local.name_prefix}-proxy"
}

resource "netbird_group" "adguard_dns" {
  name = "${local.name_prefix}-adguard-dns"
}

resource "netbird_group" "management_lan_routers" {
  name = "${local.name_prefix}-management-lan-routers"
}

resource "netbird_group" "bastion_exit_routers" {
  name = "${local.name_prefix}-bastion-exit-routers"
}

resource "netbird_group" "exit_node_users" {
  name = "${local.name_prefix}-exit-node-users"
}

resource "netbird_setup_key" "k8s_routers" {
  name                   = "${local.name_prefix}-k8s-routers"
  type                   = "reusable"
  expiry_seconds         = 0
  usage_limit            = 0
  allow_extra_dns_labels = true
  auto_groups            = [netbird_group.k8s_routers.id]
  ephemeral              = false
  revoked                = false
}

resource "netbird_setup_key" "management_vm" {
  name                   = "${local.name_prefix}-management-vm"
  type                   = "reusable"
  expiry_seconds         = 0
  usage_limit            = 1
  allow_extra_dns_labels = true
  auto_groups            = [netbird_group.management_vm.id]
  ephemeral              = false
  revoked                = false
}

resource "netbird_setup_key" "management_lan_router" {
  name                   = "${local.name_prefix}-management-lan-router"
  type                   = "reusable"
  expiry_seconds         = 0
  usage_limit            = 1
  allow_extra_dns_labels = true
  auto_groups            = [netbird_group.management_vm.id, netbird_group.management_lan_routers.id]
  ephemeral              = false
  revoked                = false
}

resource "netbird_setup_key" "proxy" {
  name                   = "${local.name_prefix}-proxy"
  type                   = "reusable"
  expiry_seconds         = 0
  usage_limit            = 1
  allow_extra_dns_labels = true
  auto_groups            = [netbird_group.proxy.id]
  ephemeral              = false
  revoked                = false
}

resource "netbird_setup_key" "bastion_exit_router" {
  name                   = "${local.name_prefix}-bastion-exit-router"
  type                   = "reusable"
  expiry_seconds         = 0
  usage_limit            = 1
  allow_extra_dns_labels = true
  auto_groups            = [netbird_group.bastion_exit_routers.id]
  ephemeral              = false
  revoked                = false
}

resource "netbird_network" "twinbox" {
  name        = local.name_prefix
  description = "Twinbox ${var.cluster_id} internal Kubernetes services"
}

resource "netbird_network_resource" "traefik" {
  network_id  = netbird_network.twinbox.id
  name        = "${local.name_prefix}-traefik"
  description = "Internal Traefik service for NetBird Reverse Proxy targets"
  address     = var.traefik_resource_address
  groups      = [data.netbird_group.all.id, netbird_group.proxy.id]
  enabled     = true
}

resource "netbird_network_router" "k8s_routers" {
  network_id  = netbird_network.twinbox.id
  peer_groups = [netbird_group.k8s_routers.id]
  metric      = 9999
  masquerade  = true
  enabled     = true
}

resource "netbird_route" "k8s_services" {
  for_each = toset(var.service_cidrs)

  network_id  = netbird_network.twinbox.id
  description = "Kubernetes service CIDR ${each.key}"
  network     = each.key
  peer_groups = [netbird_group.k8s_routers.id]
  groups      = [netbird_group.proxy.id, netbird_group.adguard_dns.id, netbird_group.admins.id, netbird_group.management_vm.id]
  masquerade  = true
  metric      = 9999
  enabled     = true
}

resource "netbird_route" "k8s_pods" {
  for_each = toset(var.pod_cidrs)

  network_id  = netbird_network.twinbox.id
  description = "Kubernetes pod CIDR ${each.key}"
  network     = each.key
  peer_groups = [netbird_group.k8s_routers.id]
  groups      = [netbird_group.proxy.id]
  masquerade  = true
  metric      = 9999
  enabled     = true
}

resource "netbird_route" "management_lan" {
  for_each = toset(var.management_lan_cidrs)

  network_id      = netbird_network.twinbox.id
  description     = "Management VM LAN CIDR ${each.key}"
  network         = each.key
  peer_groups     = [netbird_group.management_vm.id, netbird_group.management_lan_routers.id]
  groups          = [netbird_group.admins.id, netbird_group.exit_node_users.id]
  masquerade      = true
  metric          = 9999
  enabled         = true
  skip_auto_apply = var.exit_node_skip_auto_apply
}

resource "netbird_route" "hetzner_internet_exit" {
  network_id      = netbird_network.twinbox.id
  description     = "Hetzner bastion internet exit node"
  network         = "0.0.0.0/0"
  peer_groups     = [netbird_group.bastion_exit_routers.id]
  groups          = [netbird_group.admins.id, netbird_group.exit_node_users.id]
  masquerade      = true
  metric          = 9999
  enabled         = true
  skip_auto_apply = var.exit_node_skip_auto_apply
}

resource "netbird_policy" "admin_to_management_vm_ssh" {
  name        = "${local.name_prefix}-admin-to-management-vm-ssh"
  description = "Allow Twinbox admins to reach the Management VM SSH service over NetBird"
  enabled     = true

  rule {
    name          = "ssh"
    action        = "accept"
    enabled       = true
    bidirectional = true
    protocol      = "tcp"
    sources       = [netbird_group.admins.id]
    destinations  = [netbird_group.management_vm.id]
    ports         = [tostring(var.management_vm_ssh_port)]
  }
}

resource "netbird_policy" "admin_to_management_vm_web" {
  name        = "${local.name_prefix}-admin-to-management-vm-web"
  description = "Allow Twinbox admins to reach the Management VM web service over NetBird"
  enabled     = true

  rule {
    name          = "manager-web"
    action        = "accept"
    enabled       = true
    bidirectional = true
    protocol      = "tcp"
    sources       = [netbird_group.admins.id]
    destinations  = [netbird_group.management_vm.id]
    ports         = [tostring(var.management_vm_web_port)]
  }
}

resource "netbird_policy" "admin_to_management_vm_api" {
  name        = "${local.name_prefix}-admin-to-management-vm-api"
  description = "Allow Twinbox admins to reach the Management VM API service over NetBird"
  enabled     = true

  rule {
    name          = "manager-api"
    action        = "accept"
    enabled       = true
    bidirectional = true
    protocol      = "tcp"
    sources       = [netbird_group.admins.id]
    destinations  = [netbird_group.management_vm.id]
    ports         = [tostring(var.management_vm_api_port)]
  }
}

resource "netbird_policy" "exit_node_users_to_management_lan_routers_icmp" {
  name        = "${local.name_prefix}-exit-node-users-to-management-lan-routers-icmp"
  description = "Allow route users to select the Management VM LAN route"
  enabled     = true

  rule {
    name          = "icmp"
    action        = "accept"
    enabled       = true
    bidirectional = true
    protocol      = "icmp"
    sources       = [netbird_group.admins.id, netbird_group.exit_node_users.id]
    destinations  = [netbird_group.management_vm.id, netbird_group.management_lan_routers.id]
  }
}

resource "netbird_policy" "exit_node_users_to_bastion_exit_routers_icmp" {
  name        = "${local.name_prefix}-exit-node-users-to-bastion-exit-routers-icmp"
  description = "Allow route users to select the Hetzner internet exit route"
  enabled     = true

  rule {
    name          = "icmp"
    action        = "accept"
    enabled       = true
    bidirectional = true
    protocol      = "icmp"
    sources       = [netbird_group.admins.id, netbird_group.exit_node_users.id]
    destinations  = [netbird_group.bastion_exit_routers.id]
  }
}

resource "netbird_policy" "adguard_dns_to_k8s_routers" {
  name        = "${local.name_prefix}-adguard-dns-to-k8s-routers"
  description = "Allow AdGuard DNS UDP queries to reach the Kubernetes cluster via routing peers"
  enabled     = true

  rule {
    name          = "dns"
    action        = "accept"
    enabled       = true
    bidirectional = false
    protocol      = "udp"
    sources       = [netbird_group.adguard_dns.id, netbird_group.admins.id, netbird_group.exit_node_users.id]
    destinations  = [netbird_group.k8s_routers.id]
    ports         = ["53"]
  }
}

resource "netbird_policy" "adguard_dns_to_k8s_routers_tcp" {
  name        = "${local.name_prefix}-adguard-dns-to-k8s-routers-tcp"
  description = "Allow AdGuard DNS TCP queries to reach the Kubernetes cluster via routing peers"
  enabled     = true

  rule {
    name          = "dns"
    action        = "accept"
    enabled       = true
    bidirectional = false
    protocol      = "tcp"
    sources       = [netbird_group.adguard_dns.id, netbird_group.admins.id, netbird_group.exit_node_users.id]
    destinations  = [netbird_group.k8s_routers.id]
    ports         = ["53"]
  }
}

resource "netbird_policy" "adguard_dns_to_management_vm" {
  name        = "${local.name_prefix}-adguard-dns-to-management-vm"
  description = "Allow AdGuard DNS UDP queries to reach the Management VM DNS forwarder"
  enabled     = true

  rule {
    name          = "dns-forwarder"
    action        = "accept"
    enabled       = true
    bidirectional = true
    protocol      = "udp"
    sources       = [netbird_group.adguard_dns.id]
    destinations  = [netbird_group.management_vm.id]
    ports         = ["5354"]
  }
}

resource "netbird_policy" "adguard_dns_to_management_vm_tcp" {
  name        = "${local.name_prefix}-adguard-dns-to-management-vm-tcp"
  description = "Allow AdGuard DNS TCP fallback to reach the Management VM DNS forwarder"
  enabled     = true

  rule {
    name          = "dns-forwarder"
    action        = "accept"
    enabled       = true
    bidirectional = true
    protocol      = "tcp"
    sources       = [netbird_group.adguard_dns.id]
    destinations  = [netbird_group.management_vm.id]
    ports         = ["5354"]
  }
}

resource "netbird_policy" "proxy_to_traefik_https" {
  name        = "${local.name_prefix}-proxy-to-traefik-websecure"
  description = "Allow NetBird reverse proxy traffic to reach the internal Traefik websecure entrypoint"
  enabled     = true

  rule {
    name          = "websecure"
    action        = "accept"
    enabled       = true
    bidirectional = true
    protocol      = "tcp"
    sources       = [data.netbird_group.all.id]
    ports         = ["8443"]

    destination_resource = {
      id   = netbird_network_resource.traefik.id
      type = local.traefik_resource_type
    }
  }
}
