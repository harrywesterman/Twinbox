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

resource "authentik_provider_oauth2" "dashy" {
  name                  = var.application_name
  client_id             = random_string.client_id.result
  authorization_flow    = local.authentik_authorization_flow_id
  invalidation_flow     = local.authentik_invalidation_flow_id
  # Dashy sends the root start-page URL without a trailing slash.
  # Normalize the configured callback so the provider accepts both forms.
  allowed_redirect_uris = [
    {
      matching_mode = "regex"
      url           = "^${replace(replace(trim(var.dashy_redirect_uri, "/"), ".", "\\."), "/", "\\/")}(?:.*)?$"
    },
  ]
  property_mappings = data.authentik_property_mapping_provider_scope.scopes.ids
  signing_key               = data.authentik_certificate_key_pair.authentik_signing_key.id
  include_claims_in_id_token = true
  client_type               = "public"
  issuer_mode               = "per_provider"
}

resource "authentik_application" "dashy" {
  name              = var.application_name
  slug              = var.application_slug
  protocol_provider = authentik_provider_oauth2.dashy.id
}
