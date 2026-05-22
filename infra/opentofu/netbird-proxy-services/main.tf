data "netbird_reverse_proxy_clusters" "all" {}

locals {
  traefik_target_is_host = length(regexall("^([0-9]{1,3}\\.){3}[0-9]{1,3}$", var.traefik_resource_address)) > 0
  traefik_target_type    = local.traefik_target_is_host ? "host" : "domain"
  target_clusters = [
    for cluster in data.netbird_reverse_proxy_clusters.all.clusters : cluster
    if cluster.address == var.netbird_proxy_domain && try(cluster.connected_proxies, 0) > 0
  ]
  target_cluster_address = try(local.target_clusters[0].address, var.netbird_proxy_domain)
}

resource "netbird_reverse_proxy_domain" "services" {
  for_each = toset(distinct([for service in var.services : service.domain]))

  domain         = each.key
  target_cluster = local.target_cluster_address

  lifecycle {
    precondition {
      condition     = length(local.target_clusters) > 0
      error_message = "No online NetBird reverse proxy cluster found for netbird_proxy_domain. Check that the NetBird proxy container is connected and NETBIRD_PROXY_DOMAIN matches the bastion secret."
    }
  }
}

resource "netbird_reverse_proxy_service" "services" {
  for_each = { for service in var.services : service.name => service }

  depends_on = [netbird_reverse_proxy_domain.services]

  name              = each.value.name
  domain            = each.value.domain
  enabled           = true
  pass_host_header  = true
  rewrite_redirects = true

  targets = [
    {
      target_id   = var.traefik_resource_id
      target_type = local.traefik_target_type
      host        = var.traefik_resource_address
      path        = each.value.path
      port        = 443
      protocol    = "https"
      options = {
        skip_tls_verify = true
      }
      enabled     = true
    }
  ]

  auth = {
    link_auth = {
      enabled = false
    }
    password_auth = {
      enabled = false
    }
    pin_auth = {
      enabled = false
    }
    bearer_auth = {
      enabled = false
    }
  }
}
