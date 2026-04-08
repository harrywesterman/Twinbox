data "authentik_flow" "authorization" {
  slug = "default-provider-authorization-implicit-consent"
  designation = "authorization"
}

data "authentik_flow" "invalidation" {
  slug = "default-provider-invalidation-flow"
  designation = "invalidation"
}

locals {
  authentik_authorization_flow_id = "00585727-06b0-48a1-8ba3-892994c47e12"
  authentik_invalidation_flow_id  = "cc1ce8ed-a537-4b02-8558-8b16f17a2328"
}

data "authentik_property_mapping_provider_scope" "scopes" {
  managed_list = ["openid", "email", "profile"]
}

resource "tls_private_key" "argocd_signing" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_self_signed_cert" "argocd_signing" {
  private_key_pem       = tls_private_key.argocd_signing.private_key_pem
  is_ca_certificate     = false
  validity_period_hours = 87600
  allowed_uses = [
    "digital_signature",
    "key_encipherment",
  ]

  subject {
    common_name  = "${var.application_slug}.oidc-signing"
    organization = "Twinbox"
  }
}

resource "authentik_certificate_key_pair" "argocd_signing" {
  name             = "${var.application_slug}-oidc-signing"
  certificate_data = tls_self_signed_cert.argocd_signing.cert_pem
  key_data         = tls_private_key.argocd_signing.private_key_pem
}

resource "random_string" "client_id" {
  length  = 32
  upper   = false
  lower   = true
  numeric = true
  special = false
}

resource "random_password" "client_secret" {
  length  = 48
  special = false
}

resource "authentik_provider_oauth2" "argocd" {
  name                 = var.application_name
  client_id            = random_string.client_id.result
  client_secret        = random_password.client_secret.result
  authorization_flow   = local.authentik_authorization_flow_id
  invalidation_flow    = local.authentik_invalidation_flow_id
  allowed_redirect_uris = [
    {
      matching_mode = "strict"
      url           = var.argocd_redirect_uri
    },
  ]
  property_mappings = data.authentik_property_mapping_provider_scope.scopes.ids
  signing_key                = authentik_certificate_key_pair.argocd_signing.id
  include_claims_in_id_token = true
  client_type               = "confidential"
  issuer_mode               = "per_provider"
}

resource "authentik_application" "argocd" {
  name              = var.application_name
  slug              = var.application_slug
  protocol_provider = authentik_provider_oauth2.argocd.id
}
