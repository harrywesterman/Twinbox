output "application_slug" {
  description = "Authentik application slug used for the Headlamp OIDC issuer"
  value       = authentik_application.headlamp.slug
}

output "client_id" {
  description = "OAuth client ID for Headlamp"
  value       = authentik_provider_oauth2.headlamp.client_id
}

output "client_secret" {
  description = "OAuth client secret for Headlamp"
  value       = authentik_provider_oauth2.headlamp.client_secret
  sensitive   = true
}

output "issuer_url" {
  description = "OIDC issuer URL for Headlamp"
  value       = "${trim(var.authentik_url, "/")}/application/o/${var.application_slug}/"
}

output "redirect_uri" {
  description = "Headlamp OIDC callback URL"
  value       = var.headlamp_redirect_uri
}
