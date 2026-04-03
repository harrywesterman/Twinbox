variable "application_name" {
  description = "Display name for the Headlamp OIDC application"
  type        = string
  default     = "Headlamp"
}

variable "application_slug" {
  description = "Application slug used in the Authentik issuer URL"
  type        = string
  default     = "headlamp"
}

variable "authentik_url" {
  description = "Base URL of the Authentik instance"
  type        = string
}

variable "headlamp_redirect_uri" {
  description = "Headlamp OIDC callback URL"
  type        = string
}
