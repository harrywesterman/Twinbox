output "application_slug" {
  description = "Authentik application slug used for the Vaultwarden OIDC issuer"
  value       = authentik_application.vaultwarden.slug
}

output "client_id" {
  description = "OAuth client ID for Vaultwarden"
  value       = authentik_provider_oauth2.vaultwarden.client_id
}

output "client_secret" {
  description = "OAuth client secret for Vaultwarden"
  value       = authentik_provider_oauth2.vaultwarden.client_secret
  sensitive   = true
}

output "issuer_url" {
  description = "OIDC issuer URL for Vaultwarden"
  value       = "${trim(var.authentik_url, "/")}/application/o/${var.application_slug}/"
}

output "redirect_uri" {
  description = "Vaultwarden OIDC callback URL"
  value       = var.vaultwarden_redirect_uri
}
