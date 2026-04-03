variable "application_name" {
  description = "Display name for the Dashy OIDC application"
  type        = string
  default     = "Dashy"
}

variable "application_slug" {
  description = "Application slug used in the Authentik issuer URL"
  type        = string
  default     = "dashy"
}

variable "authentik_url" {
  description = "Base URL of the Authentik instance"
  type        = string
}

variable "dashy_redirect_uri" {
  description = "Dashy OIDC callback URL"
  type        = string
}
