variable "application_name" {
  description = "Display name for the pgAdmin 4 OIDC application"
  type        = string
  default     = "pgAdmin 4"
}

variable "application_slug" {
  description = "Application slug used in the Authentik issuer URL"
  type        = string
  default     = "pgadmin4"
}

variable "authentik_url" {
  description = "Base URL of the Authentik instance"
  type        = string
}

variable "pgadmin4_redirect_uri" {
  description = "pgAdmin 4 OIDC callback URL"
  type        = string
}
