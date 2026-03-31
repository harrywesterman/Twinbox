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

variable "wiredoor_record_name" {
  description = "Relative record name for the Wiredoor server"
  type        = string
  default     = "wiredoor"
}

variable "target_ipv4" {
  description = "IPv4 address of the Wiredoor server"
  type        = string
}

variable "wiredoor_record_proxied" {
  description = "Whether Cloudflare should proxy the wiredoor host"
  type        = bool
  default     = false
}

variable "wildcard_record_proxied" {
  description = "Whether Cloudflare should proxy the wildcard record"
  type        = bool
  default     = false
}