data "authentik_flow" "authorization" {
  slug        = "default-provider-authorization-implicit-consent"
  designation = "authorization"
}

data "authentik_flow" "invalidation" {
  slug        = "default-provider-invalidation-flow"
  designation = "invalidation"
}

locals {
  authentik_authorization_flow_id = data.authentik_flow.authorization.id
  authentik_invalidation_flow_id  = data.authentik_flow.invalidation.id
}

data "authentik_property_mapping_provider_scope" "scopes" {
  managed_list = ["openid", "email", "profile"]
}

data "authentik_certificate_key_pair" "authentik_signing_key" {
  name = "authentik Self-signed Certificate"
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

resource "authentik_provider_oauth2" "vaultwarden" {
  name                = var.application_name
  client_id           = random_string.client_id.result
  client_secret       = random_password.client_secret.result
  authorization_flow  = local.authentik_authorization_flow_id
  invalidation_flow   = local.authentik_invalidation_flow_id
  allowed_redirect_uris = [
    {
      matching_mode = "strict"
      url           = var.vaultwarden_redirect_uri
    },
  ]
  property_mappings          = data.authentik_property_mapping_provider_scope.scopes.ids
  signing_key                = data.authentik_certificate_key_pair.authentik_signing_key.id
  include_claims_in_id_token = true
  client_type                = "confidential"
  issuer_mode                = "per_provider"
}

resource "authentik_application" "vaultwarden" {
  name              = var.application_name
  slug              = var.application_slug
  protocol_provider = authentik_provider_oauth2.vaultwarden.id
}
