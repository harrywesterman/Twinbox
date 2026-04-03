data "authentik_flow" "authorization" {
  slug = "default-provider-authorization-implicit-consent"
}

data "authentik_flow" "invalidation" {
  slug = "default-provider-invalidation-flow"
}

data "authentik_property_mapping_provider_scope" "email" {
  name = "authentik default OAuth Mapping: OpenID 'email'"
}

data "authentik_property_mapping_provider_scope" "openid" {
  name = "authentik default OAuth Mapping: OpenID 'openid'"
}

data "authentik_property_mapping_provider_scope" "profile" {
  name = "authentik default OAuth Mapping: OpenID 'profile'"
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

resource "authentik_provider_oauth2" "headlamp" {
  name                = var.application_name
  client_id           = random_string.client_id.result
  client_secret       = random_password.client_secret.result
  authorization_flow  = data.authentik_flow.authorization.id
  invalidation_flow   = data.authentik_flow.invalidation.id
  allowed_redirect_uris = [
    {
      matching_mode = "strict"
      url           = var.headlamp_redirect_uri
    },
  ]
  property_mappings   = [
    data.authentik_property_mapping_provider_scope.email.id,
    data.authentik_property_mapping_provider_scope.openid.id,
    data.authentik_property_mapping_provider_scope.profile.id,
  ]
  include_claims_in_id_token = true
  client_type                = "confidential"
  issuer_mode                = "per_provider"
}

resource "authentik_application" "headlamp" {
  name              = var.application_name
  slug              = var.application_slug
  protocol_provider = authentik_provider_oauth2.headlamp.id
}
