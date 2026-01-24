# Twinbox Talos Linux Integration Guide

## Overview

This document provides guidance on deploying and managing Talos Linux-based Kubernetes clusters using Twinbox. Talos Linux is a modern, secure, and immutable Linux distribution designed specifically for Kubernetes. This integration maintains Twinbox's existing architecture while adapting to Talos's unique requirements and configuration model.

## Architecture

The Talos integration follows Twinbox's established two-layer architecture:

### Infrastructure Layer (Terraform)
- VM provisioning with Talos-specific requirements (UEFI, EFI disk, etc.)
- Network configuration and connectivity
- Storage management adapted for Talos installation patterns

### Configuration Layer (Talos Machine Configs)
- Declarative system configuration via Talos machine configs
- Kubernetes cluster initialization through Talos APIs
- Service deployment and configuration via Kubernetes manifests
- Security hardening through Talos's built-in features

## Prerequisites

Before deploying a Talos cluster with Twinbox, ensure you have:

- Access to a Proxmox VE environment
- Sufficient resources for your cluster (minimum 2 CPUs and 4GB RAM per node)
- Internet access for downloading Talos ISO and container images
- `terraform`, `talosctl`, and `kubectl` installed locally
- `jq` for JSON processing

## Deployment Process

### 1. Environment Setup

Set the required environment variables:

```bash
export PROXMOX_HOST="your-proxmox-host"
export PROXMOX_PORT="8006"
export PROXMOX_USER="root@pam"
export PROXMOX_PASSWORD="your-password"
export CLUSTER_NAME="my-talos-cluster"
export PROXMOX_REALM="pam"
```

### 2. Customize Cluster Configuration

Modify the following variables according to your needs:

```bash
export CONTROLPLANE_COUNT=1    # Number of control plane nodes
export WORKER_COUNT=2          # Number of worker nodes
export VM_CORES=4              # CPU cores per VM
export VM_MEMORY=4096          # Memory in MB per VM
export DISK_SIZE="20G"         # Disk size per VM
export STORAGE_POOL="local-lvm" # Proxmox storage pool
export NETWORK_BRIDGE="vmbr0"  # Network bridge
export VLAN_ID=0               # VLAN ID (0 for none)
export KUBERNETES_VERSION="1.28.0" # Kubernetes version
```

### 3. Deploy the Cluster

Run the deployment script:

```bash
./twinbox/scripts/deploy-talos-cluster.sh
```

The script will:
- Download the Talos ISO to Proxmox
- Provision VMs using Terraform
- Generate Talos machine configurations
- Apply configurations to nodes
- Bootstrap the cluster
- Generate kubeconfig for access

### 4. Access the Cluster

After deployment, access your cluster using the generated kubeconfig:

```bash
export KUBECONFIG=./twinbox/kubeconfig
kubectl get nodes
```

## Configuration Management

### Machine Configurations

Talos uses declarative machine configurations instead of traditional configuration files. Twinbox generates these configurations using templates located at:

- `twinbox/configs/talos-controlplane-template.yaml` - Control plane template
- `twinbox/configs/talos-worker-template.yaml` - Worker node template

To customize configurations, modify these templates or generate custom configurations using the configuration generator:

```bash
CLUSTER_NAME="my-cluster" \
NODE_IP="192.168.1.100" \
MACHINE_TYPE="controlplane" \
./twinbox/scripts/generate-talos-config.sh
```

### Applying Configuration Changes

To apply configuration changes to a running node:

```bash
talosctl apply-config --insecure --nodes NODE_IP --file PATH_TO_CONFIG
```

Or use the helper script:

```bash
./twinbox/scripts/proxmox-talos-helper.sh apply-config NODE_IP PATH_TO_CONFIG
```

## Management Operations

### Getting Node Information

Get IP addresses of cluster nodes:

```bash
terraform -chdir=twinbox/terraform output controlplane_ips
terraform -chdir=twinbox/terraform output worker_ips
```

### Cluster Verification

Validate cluster health:

```bash
./twinbox/tests/validate-talos-cluster.sh
```

Run comprehensive integration tests:

```bash
./twinbox/tests/integration-test-talos.sh
```

### Accessing Talos API

To interact directly with the Talos API, use talosctl:

```bash
talosctl --nodes NODE_IP config generate --force --endpoints ENDPOINT_IP
talosctl --nodes NODE_IP get machineconfig
talosctl --nodes NODE_IP reboot
talosctl --nodes NODE_IP upgrade --image ghcr.io/siderolabs/installer:latest
```

## Security Features

### Built-in Security

Talos Linux includes several security features:

- Immutable filesystem
- Minimal attack surface
- Automatic security updates
- Secure boot support
- Kernel hardening

### RBAC Configuration

Talos enables RBAC by default. To configure additional RBAC rules, apply Kubernetes manifests after cluster creation:

```bash
kubectl apply -f your-rbac-manifest.yaml
```

### Network Policies

To enhance security with network policies:

```bash
kubectl apply -f twinbox/ansible/roles/security/files/network-policies.yaml
```

## Troubleshooting

### Common Issues

#### Nodes Not Getting IP Addresses
- Check Proxmox agent is installed and running in the VM
- Verify network bridge configuration in Proxmox
- Ensure DHCP is available on the network

#### Configuration Application Failures
- Verify talosctl is configured with correct endpoints
- Check that the target node is accessible
- Ensure the configuration file is valid

#### Cluster Bootstrap Failures
- Confirm all control plane nodes are accessible
- Verify network connectivity between nodes
- Check that the cluster name is consistent across configurations

### Diagnostic Commands

Get machine information:
```bash
talosctl --nodes NODE_IP get machineconfig
```

Check logs:
```bash
talosctl --nodes NODE_IP logs kubelet
```

View cluster status:
```bash
talosctl --nodes NODE_IP cluster health
```

### Log Files

Talos logs can be accessed via:
- `talosctl --nodes NODE_IP logs <service-name>` - For specific service logs
- `journalctl` - On the Talos node itself (via console access)

## Maintenance

### Upgrading Talos

To upgrade Talos nodes:

```bash
talosctl --nodes NODE_IP upgrade --image ghcr.io/siderolabs/installer:v1.6.0
```

### Backup and Recovery

Talos provides built-in backup capabilities for etcd. For additional backups, consider:

- Backing up the generated machine configurations
- Regular Kubernetes resource backups using Velero or similar tools
- Snapshotting VMs in Proxmox for disaster recovery

### Scaling Clusters

To scale your cluster, modify the Terraform variables and reapply:

1. Update `twinbox/terraform/talos-cluster.auto.tfvars`
2. Run `terraform -chdir=twinbox/terraform apply`
3. Generate and apply new configurations for new nodes

## Integration with Existing Twinbox Services

### Monitoring Integration

Existing Twinbox monitoring components can be deployed to Talos clusters using standard Kubernetes manifests:

```bash
kubectl apply -f twinbox/ansible/roles/monitoring/files/prometheus-stack.yaml
kubectl apply -f twinbox/ansible/roles/monitoring/files/grafana-dashboard.yaml
```

### Security Integration

Apply Twinbox security policies:

```bash
kubectl apply -f twinbox/ansible/roles/security/files/rbac-admin-user.yaml
kubectl apply -f twinbox/ansible/roles/security/files/network-policies.yaml
```

### Addon Integration

Deploy Twinbox addons:

```bash
kubectl apply -f twinbox/ansible/roles/addons/files/metallb-native.yaml
kubectl apply -f twinbox/ansible/roles/addons/files/nginx-ingress.yaml
```

## Best Practices

### Resource Planning

- Allocate sufficient resources: minimum 2 CPU cores and 4GB RAM per node
- Plan for overhead: Talos has minimal overhead compared to traditional OS
- Consider resource requirements for your applications

### High Availability

For production deployments:
- Deploy at least 3 control plane nodes for etcd quorum
- Distribute nodes across different physical hosts
- Implement proper backup strategies

### Security

- Regularly update Talos to latest stable version
- Monitor cluster for security advisories
- Implement network segmentation
- Use least-privilege principles for workloads

### Monitoring

- Monitor both infrastructure and application metrics
- Set up alerting for critical issues
- Track cluster performance over time
- Monitor Talos-specific metrics

## Limitations

- Talos Linux requires UEFI boot mode
- Limited customization compared to traditional Linux distributions
- Different operational model requiring adjustment from traditional approaches
- Some legacy applications may not work without modification

## Migration from Traditional Clusters

Existing Twinbox users can gradually adopt Talos clusters alongside traditional Kubernetes clusters, allowing for comparison and gradual migration as needed. The deployment and management interfaces remain consistent with Twinbox patterns.