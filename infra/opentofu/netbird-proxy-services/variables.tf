variable "netbird_token" {
  description = "NetBird Management API personal access token"
  type        = string
  sensitive   = true
}

variable "netbird_management_url" {
  description = "NetBird Management API URL"
  type        = string
}

variable "traefik_resource_id" {
  description = "NetBird network resource ID for Traefik"
  type        = string
}

variable "traefik_resource_address" {
  description = "Internal Traefik address used as the reverse proxy target host or domain"
  type        = string
}

variable "services" {
  description = "Reverse proxy services to expose through NetBird"
  type = list(object({
    name   = string
    domain = string
    path   = optional(string, "/")
  }))
  default = []
}
