variable "hcloud_token" {
  description = "Hetzner Cloud API token"
  type        = string
  sensitive   = true
}

variable "ssh_public_key" {
  description = "Public SSH key content"
  type        = string
}

variable "server_name" {
  description = "Hetzner server name"
  type        = string
  default     = "netbird-1"
}

variable "server_type" {
  description = "Hetzner server type"
  type        = string
  default     = "cax11"
}

variable "image" {
  description = "Hetzner image"
  type        = string
  default     = "debian-13"
}

variable "location" {
  description = "Hetzner location"
  type        = string
  default     = "fsn1"
}

variable "labels" {
  description = "Extra Hetzner labels"
  type        = map(string)
  default     = {}
}

variable "netbird_fqdn" {
  description = "Full public hostname for NetBird, e.g. netbird.example.com"
  type        = string
}

variable "netbird_proxy_domain" {
  description = "Base public hostname for NetBird reverse proxy services, e.g. proxy.example.com"
  type        = string
}

variable "public_zone_name" {
  description = "Public DNS zone used to seed NetBird single-account mode, e.g. example.com"
  type        = string
}

variable "netbird_admin_email" {
  description = "Email used for Let's Encrypt certificates"
  type        = string
}

variable "netbird_version" {
  description = "NetBird Docker image version tag"
  type        = string
  default     = "0.70.5"
}

variable "allowed_ssh_cidrs" {
  description = "CIDRs allowed to SSH to the VM"
  type        = list(string)
  default     = ["0.0.0.0/0", "::/0"]
}
