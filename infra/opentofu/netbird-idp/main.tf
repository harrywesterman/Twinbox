resource "netbird_identity_provider" "authentik" {
  name          = var.name
  type          = "oidc"
  client_id     = var.client_id
  client_secret = var.client_secret
  issuer        = var.issuer
}
