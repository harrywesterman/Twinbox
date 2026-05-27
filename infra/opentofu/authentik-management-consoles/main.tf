data "authentik_flow" "authorization" {
  slug = "default-provider-authorization-implicit-consent"
  designation = "authorization"
}

data "authentik_flow" "invalidation" {
  slug = "default-provider-invalidation-flow"
  designation = "invalidation"
}

locals {
  authentik_authorization_flow_id = data.authentik_flow.authorization.id
  authentik_invalidation_flow_id  = data.authentik_flow.invalidation.id
}

data "authentik_group" "admins" {
  name = var.admins_group_name
}

locals {
  apps = {
    traefik_dashboard = {
      name          = "Traefik Dashboard"
      slug          = "traefik-dashboard"
      external_host = var.traefik_dashboard_external_host
      launch_url    = "${trim(var.traefik_dashboard_external_host, "/")}/dashboard/"
    }
    longhorn = {
      name          = "Longhorn"
      slug          = "longhorn"
      external_host = var.longhorn_external_host
      launch_url    = var.longhorn_external_host
    }
    proxmox = {
      name          = "Proxmox"
      slug          = "proxmox"
      external_host = var.proxmox_external_host
      launch_url    = var.proxmox_external_host
    }
    webwizard = {
      name          = "Web Wizard"
      slug          = "webwizard"
      external_host = var.webwizard_external_host
      launch_url    = var.webwizard_external_host
    }
    seaweedfs = {
      name          = "SeaweedFS"
      slug          = "seaweedfs"
      external_host = var.seaweedfs_external_host
      launch_url    = var.seaweedfs_external_host
    }
    seaweedfs_admin = {
      name          = "SeaweedFS Admin"
      slug          = "seaweedfs-admin"
      external_host = var.seaweedfs_admin_external_host
      launch_url    = var.seaweedfs_admin_external_host
    }
  }
}

resource "authentik_provider_proxy" "management_console" {
  for_each = local.apps

  name               = each.value.name
  external_host      = each.value.external_host
  authorization_flow = local.authentik_authorization_flow_id
  invalidation_flow  = local.authentik_invalidation_flow_id
  mode               = "forward_single"
}

resource "authentik_application" "management_console" {
  for_each = local.apps

  name              = each.value.name
  slug              = each.value.slug
  meta_launch_url   = each.value.launch_url
  protocol_provider = authentik_provider_proxy.management_console[each.key].id
}

resource "authentik_policy_binding" "management_console_admins" {
  for_each = local.apps

  target = authentik_application.management_console[each.key].uuid
  group  = data.authentik_group.admins.id
  order  = 1
}
