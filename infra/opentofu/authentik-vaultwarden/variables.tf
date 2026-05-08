variable "application_name" {
  description = "Display name for the Vaultwarden OIDC application"
  type        = string
  default     = "Vaultwarden"
}

variable "application_slug" {
  description = "Application slug used in the Authentik issuer URL"
  type        = string
  default     = "vaultwarden"
}

variable "authentik_url" {
  description = "Base URL of the Authentik instance"
  type        = string
}

variable "vaultwarden_redirect_uri" {
  description = "Vaultwarden OIDC callback URL"
  type        = string
}
