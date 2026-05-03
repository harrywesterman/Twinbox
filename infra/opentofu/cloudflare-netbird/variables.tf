variable "cloudflare_api_token" {
  description = "Cloudflare API token"
  type        = string
  sensitive   = true
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID"
  type        = string
}

variable "zone_name" {
  description = "Cloudflare zone name, e.g. example.com"
  type        = string
}

variable "netbird_record_name" {
  description = "Relative record name for the NetBird server"
  type        = string
  default     = "netbird"
}

variable "proxy_record_name" {
  description = "Relative record name for the NetBird proxy cluster"
  type        = string
  default     = "proxy"
}

variable "target_ipv4" {
  description = "IPv4 address of the NetBird server"
  type        = string
}
