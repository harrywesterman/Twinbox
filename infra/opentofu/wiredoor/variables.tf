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
  default     = "wiredoor-1"
}

variable "server_type" {
  description = "Hetzner server type"
  type        = string
  default     = "cax11"
}

variable "image" {
  description = "Hetzner image"
  type        = string
  default     = "debian-12"
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

variable "wiredoor_fqdn" {
  description = "Full public hostname for Wiredoor, e.g. wiredoor.example.com"
  type        = string
}

variable "wiredoor_admin_email" {
  description = "Wiredoor admin email"
  type        = string
}

variable "wiredoor_admin_password" {
  description = "Wiredoor admin password"
  type        = string
  sensitive   = true
}

variable "wiredoor_vpn_port" {
  description = "Wiredoor WireGuard UDP port"
  type        = number
  default     = 51820
}

variable "wiredoor_tcp_service_port_range" {
  description = "Optional TCP service port range exposed by Wiredoor"
  type        = string
  default     = "32760-32767"
}

variable "allowed_ssh_cidrs" {
  description = "CIDRs allowed to SSH to the VM"
  type        = list(string)
  default     = ["0.0.0.0/0", "::/0"]
}