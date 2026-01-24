variable "proxmox_api_url" {
  description = "Proxmox API URL"
  type        = string
}

variable "proxmox_user" {
  description = "Proxmox username"
  type        = string
}

variable "proxmox_password" {
  description = "Proxmox password"
  type        = string
}

variable "proxmox_tls_insecure" {
  description = "Skip TLS verification for Proxmox API"
  type        = bool
  default     = true
}

variable "target_node" {
  description = "Target Proxmox node for VM deployment"
  type        = string
  default     = "pve"
}

variable "cluster_name" {
  description = "Name of the Kubernetes cluster"
  type        = string
  default     = "twinbox-cluster"
}

variable "vm_template" {
  description = "Base VM template for Kubernetes nodes"
  type        = string
  default     = "ubuntu-template"
}

variable "storage_pool" {
  description = "Storage pool for VM disks"
  type        = string
  default     = "local-lvm"
}

variable "network_bridge" {
  description = "Network bridge for VMs"
  type        = string
  default     = "vmbr0"
}

variable "master_count" {
  description = "Number of master nodes"
  type        = number
  default     = 1
}

variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 2
}

variable "master_cores" {
  description = "CPU cores for master nodes"
  type        = number
  default     = 2
}

variable "master_memory" {
  description = "Memory (MB) for master nodes"
  type        = number
  default     = 4096
}

variable "master_disk_size" {
  description = "Disk size (GB) for master nodes"
  type        = string
  default     = "20G"
}

variable "worker_cores" {
  description = "CPU cores for worker nodes"
  type        = number
  default     = 2
}

variable "worker_memory" {
  description = "Memory (MB) for worker nodes"
  type        = number
  default     = 4096
}

variable "worker_disk_size" {
  description = "Disk size (GB) for worker nodes"
  type        = string
  default     = "40G"
}