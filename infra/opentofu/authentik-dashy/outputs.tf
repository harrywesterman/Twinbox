output "application_slug" {
  description = "Authentik application slug used for the Dashy OIDC issuer"
  value       = authentik_application.dashy.slug
}

output "client_id" {
  description = "OAuth client ID for Dashy"
  value       = authentik_provider_oauth2.dashy.client_id
}

output "issuer_url" {
  description = "OIDC issuer URL for Dashy"
  value       = "${trim(var.authentik_url, "/")}/application/o/${var.application_slug}/"
}

output "redirect_uri" {
  description = "Dashy OIDC callback URL"
  value       = var.dashy_redirect_uri
}
