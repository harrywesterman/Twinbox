variable "authentik_url" {
  description = "Base URL of the Authentik instance"
  type        = string
}

variable "admins_group_name" {
  description = "Authentik group that is allowed to access the management consoles"
  type        = string
  default     = "admins"
}

variable "traefik_dashboard_external_host" {
  description = "Public URL that Authentik should associate with Traefik dashboard traffic"
  type        = string
}

variable "longhorn_external_host" {
  description = "Public URL that Authentik should associate with Longhorn traffic"
  type        = string
}
