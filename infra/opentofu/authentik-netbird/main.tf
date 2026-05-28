data "authentik_flow" "authorization" {
  slug        = "default-provider-authorization-explicit-consent"
  designation = "authorization"
}

data "authentik_flow" "invalidation" {
  slug        = "default-provider-invalidation-flow"
  designation = "invalidation"
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

resource "authentik_provider_oauth2" "netbird" {
  name               = var.application_name
  client_id          = random_string.client_id.result
  client_secret      = random_password.client_secret.result
  authorization_flow = data.authentik_flow.authorization.id
  invalidation_flow  = data.authentik_flow.invalidation.id
  allowed_redirect_uris = [
    {
      matching_mode = "regex"
      url           = "${trim(var.netbird_url, "/")}/.*"
    },
    {
      matching_mode = "strict"
      url           = "http://localhost:53000"
    },
    {
      matching_mode = "strict"
      url           = "http://localhost:53000/"
    },
  ]
  property_mappings          = var.property_mapping_ids
  signing_key                = data.authentik_certificate_key_pair.authentik_signing_key.id
  include_claims_in_id_token = true
  client_type                = "confidential"
  issuer_mode                = "per_provider"
}

resource "authentik_application" "netbird" {
  name              = var.application_name
  slug              = var.application_slug
  protocol_provider = authentik_provider_oauth2.netbird.id
}
