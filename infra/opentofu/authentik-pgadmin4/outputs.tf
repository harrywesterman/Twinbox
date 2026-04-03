output "application_slug" {
  description = "Authentik application slug used for the pgAdmin 4 OIDC issuer"
  value       = authentik_application.pgadmin4.slug
}

output "client_id" {
  description = "OAuth client ID for pgAdmin 4"
  value       = authentik_provider_oauth2.pgadmin4.client_id
}

output "client_secret" {
  description = "OAuth client secret for pgAdmin 4"
  value       = authentik_provider_oauth2.pgadmin4.client_secret
  sensitive   = true
}

output "issuer_url" {
  description = "OIDC issuer URL for pgAdmin 4"
  value       = "${trim(var.authentik_url, "/")}/application/o/${var.application_slug}/"
}

output "redirect_uri" {
  description = "pgAdmin 4 OIDC callback URL"
  value       = var.pgadmin4_redirect_uri
}
