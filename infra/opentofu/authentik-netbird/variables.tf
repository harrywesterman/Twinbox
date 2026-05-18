variable "application_name" {
  description = "Display name for the NetBird OIDC application"
  type        = string
  default     = "NetBird"
}

variable "application_slug" {
  description = "Application slug used in the Authentik issuer URL"
  type        = string
  default     = "netbird"
}

variable "authentik_api_url" {
  description = "Base URL used by the Authentik provider for API calls"
  type        = string
}

variable "authentik_public_url" {
  description = "Public base URL of the Authentik instance used for OIDC issuer URLs"
  type        = string
}

variable "netbird_url" {
  description = "Base URL of the NetBird dashboard"
  type        = string
}

variable "property_mapping_ids" {
  description = "Authentik OAuth scope property mapping IDs for openid, email, and profile"
  type        = list(string)
}
