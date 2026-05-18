data "netbird_reverse_proxy_clusters" "all" {}

resource "netbird_reverse_proxy_domain" "services" {
  for_each = toset(distinct([for service in var.services : service.domain]))

  domain         = each.key
  target_cluster = data.netbird_reverse_proxy_clusters.all.clusters[0].address
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
      target_type = "host"
      host        = var.traefik_resource_address
      path        = each.value.path
      port        = 80
      protocol    = "http"
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
