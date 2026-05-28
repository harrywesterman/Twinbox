output "application_slug" {
  description = "Authentik application slug used for the NetBird OIDC issuer"
  value       = authentik_application.netbird.slug
}

output "client_id" {
  description = "OAuth client ID for NetBird"
  value       = authentik_provider_oauth2.netbird.client_id
}

output "client_secret" {
  description = "OAuth client secret for NetBird"
  value       = authentik_provider_oauth2.netbird.client_secret
  sensitive   = true
}

output "provider_pk" {
  description = "Authentik OAuth provider primary key for NetBird"
  value       = authentik_provider_oauth2.netbird.id
}

output "issuer_url" {
  description = "OIDC issuer URL for NetBird"
  value       = "${trim(var.authentik_public_url, "/")}/application/o/${var.application_slug}/"
}
