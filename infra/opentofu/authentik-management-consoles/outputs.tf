output "provider_ids" {
  description = "Proxy provider IDs for the management consoles"
  value = {
    traefik_dashboard = authentik_provider_proxy.management_console["traefik_dashboard"].id
    longhorn          = authentik_provider_proxy.management_console["longhorn"].id
    proxmox           = authentik_provider_proxy.management_console["proxmox"].id
    webwizard         = authentik_provider_proxy.management_console["webwizard"].id
    seaweedfs         = authentik_provider_proxy.management_console["seaweedfs"].id
    seaweedfs_admin   = authentik_provider_proxy.management_console["seaweedfs_admin"].id
  }
}

output "application_slugs" {
  description = "Authentik application slugs for the management consoles"
  value = {
    traefik_dashboard = authentik_application.management_console["traefik_dashboard"].slug
    longhorn          = authentik_application.management_console["longhorn"].slug
    proxmox           = authentik_application.management_console["proxmox"].slug
    webwizard         = authentik_application.management_console["webwizard"].slug

    webwizard         = authentik_application.management_console["webwizard"].meta_launch_url
    seaweedfs         = authentik_application.management_console["seaweedfs"].meta_launch_url
    seaweedfs_admin   = authentik_application.management_console["seaweedfs_admin"].meta_launch_url
  }
}
