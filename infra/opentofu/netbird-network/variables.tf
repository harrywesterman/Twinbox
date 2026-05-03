variable "netbird_token" {
  description = "NetBird Management API personal access token"
  type        = string
  sensitive   = true
}

variable "netbird_management_url" {
  description = "NetBird Management API URL"
  type        = string
}

variable "cluster_id" {
  description = "Twinbox cluster identifier"
  type        = string
}

variable "traefik_resource_address" {
  description = "Internal Traefik resource address reachable from NetBird Kubernetes routing peers"
  type        = string
}

variable "management_vm_ssh_port" {
  description = "SSH port on the Twinbox Management VM"
  type        = number
  default     = 22
}

variable "management_vm_web_port" {
  description = "Manager web port on the Twinbox Management VM"
  type        = number
  default     = 3000
}

variable "management_vm_api_port" {
  description = "Manager API port on the Twinbox Management VM"
  type        = number
  default     = 8080
}
