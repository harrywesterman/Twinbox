variable "application_name" {
  description = "Display name for the Argo CD OIDC application"
  type        = string
  default     = "Argo CD"
}

variable "application_slug" {
  description = "Application slug used in the Authentik issuer URL"
  type        = string
  default     = "argocd"
}

variable "authentik_url" {
  description = "Base URL of the Authentik instance"
  type        = string
}

variable "argocd_redirect_uri" {
  description = "Argo CD OIDC callback URL"
  type        = string
}
