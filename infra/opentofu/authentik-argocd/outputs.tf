output "application_slug" {
  description = "Authentik application slug used for the Argo CD OIDC issuer"
  value       = authentik_application.argocd.slug
}

output "client_id" {
  description = "OAuth client ID for Argo CD"
  value       = authentik_provider_oauth2.argocd.client_id
}

output "client_secret" {
  description = "OAuth client secret for Argo CD"
  value       = authentik_provider_oauth2.argocd.client_secret
  sensitive   = true
}

output "issuer_url" {
  description = "OIDC issuer URL for Argo CD"
  value       = "${trim(var.authentik_url, "/")}/application/o/${var.application_slug}/"
}

output "redirect_uri" {
  description = "Argo CD OIDC callback URL"
  value       = var.argocd_redirect_uri
}
