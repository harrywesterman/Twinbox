# Troubleshooting Guide

This guide helps diagnose and resolve common issues with Twinbox deployments.

## Common Issues

### Terraform Errors

**Error: Failed to query available provider packages**

This usually occurs when Terraform cannot reach the provider registries. Check your internet connection and proxy settings.

**Error: Provider "proxmox" not available**

Ensure you have the correct Proxmox provider configured in your Terraform files:

```hcl
terraform {
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "~> 2.9"
    }
  }
}
```

### Ansible Errors

**Error: Connection refused when connecting to VMs**

1. Verify that the VMs were created successfully in Proxmox
2. Check that the SSH keys are properly configured
3. Ensure the VMs have network connectivity

**Error: Kubernetes cluster already initialized**

If you need to redeploy, first reset the cluster:

```bash
kubeadm reset
systemctl stop kubelet
rm -rf /etc/kubernetes/manifests/*
```

### Kubernetes Issues

**Pods stuck in Pending state**

Check resource availability:

```bash
kubectl describe nodes
kubectl get resourcequota
```

Verify that you have sufficient resources and proper storage classes configured.

**Services not accessible via LoadBalancer**

1. Verify MetalLB is running:
   ```bash
   kubectl get pods -n metallb-system
   ```

2. Check MetalLB configuration:
   ```bash
   kubectl get ipaddresspools -n metallb-system
   kubectl get l2advertisements -n metallb-system
   ```

## Debugging Steps

### 1. Check Terraform State

```bash
cd terraform
terraform show
terraform state list
```

### 2. Verify VM Creation

Log into your Proxmox web interface and verify that the VMs were created with the expected specifications.

### 3. Check VM Connectivity

Test SSH connectivity to each VM:

```bash
ssh ubuntu@<vm-ip-address>
```

### 4. Examine Kubernetes Nodes

```bash
kubectl get nodes -o wide
kubectl describe nodes
```

### 5. Check Pod Status

```bash
kubectl get pods --all-namespaces -o wide
kubectl get events --all-namespaces
```

### 6. Review Logs

For specific pods:

```bash
kubectl logs <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace> -c <container-name>
```

## Reset Procedures

If you need to completely reset your deployment:

### Reset Kubernetes Cluster

On each node:

```bash
sudo kubeadm reset
sudo systemctl stop kubelet
sudo rm -rf /etc/kubernetes/manifests/*
sudo rm -rf /var/lib/etcd/
sudo systemctl start kubelet
```

### Destroy Infrastructure

```bash
cd terraform
terraform destroy
```

## Support Resources

- Check the GitHub issues page for known issues
- Review the official documentation
- Join our community forums for assistance