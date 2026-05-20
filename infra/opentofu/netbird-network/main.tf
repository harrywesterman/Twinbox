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

resource "netbird_network_resource" "adguard" {
  network_id  = netbird_network.twinbox.id
  name        = "${local.name_prefix}-adguard"
  description = "AdGuard Home DNS server for NetBird peers"
  address     = var.adguard_resource_address
  groups      = [data.netbird_group.all.id]
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

  network_id  = "k8s-services-${var.cluster_id}"
  description = "Kubernetes service CIDR ${each.key}"
  network     = each.key
  peer_groups = [netbird_group.k8s_routers.id]
  groups      = [netbird_group.proxy.id]
  masquerade  = true
  metric      = 9999
  enabled     = true
}

resource "netbird_route" "adguard_dns" {
  network_id  = "adguard-dns-${var.cluster_id}"
  description = "Route DNS traffic to AdGuard Home"
  network     = "0.0.0.0/0"
  peer_groups = [netbird_group.adguard_dns.id]
  groups      = [data.netbird_group.all.id]
  masquerade  = false
  metric      = 1000
  enabled     = true
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

resource "netbird_policy" "proxy_to_traefik_http" {
  name        = "${local.name_prefix}-proxy-to-traefik-netbird"
  description = "Allow NetBird reverse proxy traffic to reach the internal Traefik NetBird entrypoint"
  enabled     = true

  rule {
    name          = "webnetbird"
    action        = "accept"
    enabled       = true
    bidirectional = true
    protocol      = "tcp"
    sources       = [data.netbird_group.all.id]
    ports         = ["8082"]

    destination_resource = {
      id   = netbird_network_resource.traefik.id
      type = local.traefik_resource_type
    }
  }
}

resource "netbird_policy" "all_to_adguard_dns" {
  name        = "${local.name_prefix}-all-to-adguard-dns"
  description = "Allow all NetBird peers to reach AdGuard Home DNS"
  enabled     = true

  rule {
    name          = "dns"
    action        = "accept"
    enabled       = true
    bidirectional = true
    protocol      = "udp"
    sources       = [data.netbird_group.all.id]
    ports         = ["53"]

    destination_resource = {
      id   = netbird_network_resource.adguard.id
      type = "domain"
    }
  }

  rule {
    name          = "dns-tcp"
    action        = "accept"
    enabled       = true
    bidirectional = true
    protocol      = "tcp"
    sources       = [data.netbird_group.all.id]
    ports         = ["53"]

    destination_resource = {
      id   = netbird_network_resource.adguard.id
      type = "domain"
    }
  }
}
