variable "cluster_name" {
  description = "Name of the Talos cluster"
  type        = string
  default     = "talos-cluster"
}

variable "node_type" {
  description = "Type of node (controlplane or worker)"
  type        = string
  default     = "controlplane"
}

variable "node_count" {
  description = "Number of nodes to create"
  type        = number
  default     = 1
}

variable "proxmox_target_node" {
  description = "Target Proxmox node for VM placement"
  type        = string
  default     = "pve"
}

variable "vm_template_name" {
  description = "Base template for Talos VMs (empty for fresh install)"
  type        = string
  default     = ""
}

variable "vm_cores" {
  description = "Number of CPU cores per VM"
  type        = number
  default     = 4
}

variable "vm_memory" {
  description = "Memory in MB per VM"
  type        = number
  default     = 4096
}

variable "disk_size" {
  description = "Disk size for each VM"
  type        = string
  default     = "20G"
}

variable "storage_pool" {
  description = "Storage pool for VM disks"
  type        = string
  default     = "local-lvm"
}

variable "network_bridge" {
  description = "Network bridge for VM connectivity"
  type        = string
  default     = "vmbr0"
}

variable "vlan_id" {
  description = "VLAN ID for network isolation (0 for none)"
  type        = number
  default     = 0
}

variable "talos_iso_path" {
  description = "Path to Talos Linux ISO in Proxmox storage"
  type        = string
  default     = "local:iso/talos-amd64.iso"
}