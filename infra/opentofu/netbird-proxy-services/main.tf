resource "netbird_reverse_proxy_service" "services" {
  for_each = { for service in var.services : service.name => service }

  name              = each.value.name
  domain            = each.value.domain
  enabled           = true
  pass_host_header  = true
  rewrite_redirects = true

  targets {
    target_id   = var.traefik_resource_id
    target_type = "host"
    host        = var.traefik_resource_address
    path        = each.value.path
    port        = 80
    protocol    = "http"
    enabled     = true
  }

  auth {
    link_auth {
      enabled = false
    }

    password_auth {
      enabled = false
    }

    pin_auth {
      enabled = false
    }

    bearer_auth {
      enabled = false
    }
  }
}
