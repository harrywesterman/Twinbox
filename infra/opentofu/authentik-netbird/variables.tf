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

variable "authentik_url" {
  description = "Base URL of the Authentik instance"
  type        = string
}

variable "netbird_url" {
  description = "Base URL of the NetBird dashboard"
  type        = string
}
