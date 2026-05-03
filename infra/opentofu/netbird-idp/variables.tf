variable "netbird_token" {
  description = "NetBird Management API personal access token"
  type        = string
  sensitive   = true
}

variable "netbird_management_url" {
  description = "NetBird Management API URL"
  type        = string
}

variable "name" {
  description = "Identity provider display name"
  type        = string
  default     = "Authentik"
}

variable "client_id" {
  description = "OIDC client ID"
  type        = string
}

variable "client_secret" {
  description = "OIDC client secret"
  type        = string
  sensitive   = true
}

variable "issuer" {
  description = "OIDC issuer URL"
  type        = string
}
