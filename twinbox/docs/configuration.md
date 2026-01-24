# Configuration Guide

This guide explains how to customize your Twinbox deployment.

## Terraform Variables

All infrastructure configuration is done through Terraform variables. Create a `terraform/terraform.tfvars` file with the following variables:

### Proxmox Connection
```hcl
proxmox_api_url      = "https://your-proxmox-host:8006/api2/json"
proxmox_user         = "root@pam"
proxmox_password     = "your-password"
proxmox_tls_insecure = true  # Set to false in production
```

### Cluster Configuration
```hcl
cluster_name    = "my-cluster"
target_node     = "pve"
vm_template     = "ubuntu-template"
storage_pool    = "local-lvm"
network_bridge  = "vmbr0"
```

### Node Specifications
```hcl
master_count       = 1
worker_count       = 2
master_cores       = 2
master_memory      = 4096
master_disk_size   = "20G"
worker_cores       = 4
worker_memory      = 8192
worker_disk_size   = "50G"
```

## Ansible Variables

Additional configuration can be set in `ansible/group_vars/all.yml`:

```yaml
kubernetes_version: "v1.28.0"
container_runtime: "containerd"
cni_plugin: "calico"  # or "cilium"
pod_network_cidr: "192.168.0.0/16"
```

## Customizing Components

### Changing the CNI Plugin

To use Cilium instead of Calico, update the `cni_plugin` variable:

```yaml
cni_plugin: "cilium"
```

### Adjusting Resource Quotas

In the user management section, you can adjust resource quotas:

```yaml
# In user management configuration
requests.cpu: "8"
requests.memory: 16Gi
limits.cpu: "16"
limits.memory: 32Gi
```

## MetalLB Configuration

The default MetalLB IP pool is configured for 192.168.1.100-192.168.1.110. To change this:

1. Edit the MetalLB configuration in the addons role
2. Update the IP range to match your network

## Storage Classes

Twinbox creates a default `fast-ssd` storage class. To customize:

1. Modify the storage class definition in the addons role
2. Adjust parameters like `provisioner`, `parameters`, and `volumeBindingMode`