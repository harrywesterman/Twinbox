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

variable "proxmox_external_host" {
  description = "Public URL that Authentik should associate with Proxmox traffic"
  type        = string
}

variable "webwizard_external_host" {
  description = "Public URL that Authentik should associate with the Twinbox wizard traffic"
  type        = string
}

variable "seaweedfs_external_host" {
  description = "Public URL that Authentik should associate with the SeaweedFS filer traffic"
  type        = string
}

variable "seaweedfs_admin_external_host" {
  description = "Public URL that Authentik should associate with the SeaweedFS admin traffic"
  type        = string
}
