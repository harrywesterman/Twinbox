output "provider_ids" {
  description = "Proxy provider IDs for the management consoles"
  value = {
    traefik_dashboard = authentik_provider_proxy.management_console["traefik_dashboard"].id
    longhorn          = authentik_provider_proxy.management_console["longhorn"].id
    twinboxwizard     = authentik_provider_proxy.management_console["twinboxwizard"].id
  }
}

output "application_slugs" {
  description = "Authentik application slugs for the management consoles"
  value = {
    traefik_dashboard = authentik_application.management_console["traefik_dashboard"].slug
    longhorn          = authentik_application.management_console["longhorn"].slug
    twinboxwizard     = authentik_application.management_console["twinboxwizard"].slug
  }
}

output "launch_urls" {
  description = "Public launch URLs for the management consoles"
  value = {
    traefik_dashboard = authentik_application.management_console["traefik_dashboard"].meta_launch_url
    longhorn          = authentik_application.management_console["longhorn"].meta_launch_url
    twinboxwizard     = authentik_application.management_console["twinboxwizard"].meta_launch_url
  }
}
