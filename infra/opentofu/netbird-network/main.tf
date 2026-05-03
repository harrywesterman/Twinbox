locals {
  name_prefix = "twinbox-${var.cluster_id}"
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
  groups      = [netbird_group.proxy.id]
  enabled     = true
}

resource "netbird_network_router" "k8s_routers" {
  network_id  = netbird_network.twinbox.id
  peer_groups = [netbird_group.k8s_routers.id]
  metric      = 9999
  masquerade  = true
  enabled     = true
}

resource "netbird_policy" "admin_to_management_vm" {
  name        = "${local.name_prefix}-admin-to-management-vm"
  description = "Allow Twinbox admins to reach the Management VM over NetBird"
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

resource "netbird_policy" "proxy_to_traefik" {
  name        = "${local.name_prefix}-proxy-to-traefik"
  description = "Allow NetBird proxy traffic to reach internal Traefik"
  enabled     = true

  rule {
    name          = "http"
    action        = "accept"
    enabled       = true
    bidirectional = true
    protocol      = "tcp"
    sources       = [netbird_group.proxy.id]
    ports         = ["80"]

    destination_resource = {
      id   = netbird_network_resource.traefik.id
      type = "host"
    }
  }

  rule {
    name          = "https"
    action        = "accept"
    enabled       = true
    bidirectional = true
    protocol      = "tcp"
    sources       = [netbird_group.proxy.id]
    ports         = ["443"]

    destination_resource = {
      id   = netbird_network_resource.traefik.id
      type = "host"
    }
  }
}
