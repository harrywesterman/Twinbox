# Twinbox

Twinbox is a comprehensive infrastructure automation platform for deploying and managing Kubernetes clusters on Proxmox VE. It provides a complete solution for infrastructure as code, configuration management, and operational tooling.

## Features

- **Infrastructure as Code**: Terraform modules for provisioning VMs on Proxmox
- **Configuration Management**: Ansible playbooks for cluster setup and configuration
- **Multiple Kubernetes Distributions**: Support for both traditional Kubernetes and Talos Linux
- **Security**: Built-in security hardening and RBAC configuration
- **Monitoring**: Integrated monitoring stack with Prometheus and Grafana
- **Networking**: CNI plugin configuration and ingress setup
- **Storage**: Persistent storage configuration
- **User Management**: Identity and access management integration

## Quick Start

### Prerequisites

- Proxmox VE environment
- Terraform installed
- Ansible installed
- Sufficient hardware resources

### Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/your-org/twinbox.git
   cd twinbox
   ```

2. Configure environment variables:
   ```bash
   export PROXMOX_HOST="your-proxmox-host"
   export PROXMOX_USER="root@pam"
   export PROXMOX_PASSWORD="your-password"
   ```

3. Deploy your cluster:
   ```bash
   ./twinbox/scripts/deploy.sh
   ```

## Talos Linux Integration

Twinbox now includes full support for Talos Linux, a modern, secure, and immutable Linux distribution designed specifically for Kubernetes. The Talos integration provides:

- Automated VM provisioning with UEFI and EFI disk requirements
- Machine configuration generation and application
- Seamless cluster bootstrap and validation
- Integration with existing Twinbox monitoring and security features

To deploy a Talos cluster, use the dedicated deployment script:

```bash
./twinbox/scripts/deploy-talos-cluster.sh
```

See the [Talos Integration Guide](twinbox/docs/talos-integration.md) for detailed documentation.

## Architecture

Twinbox follows a two-layer architecture:

### Infrastructure Layer (Terraform)
- VM provisioning on Proxmox VE
- Network and storage configuration
- Load balancer setup (if needed)

### Configuration Layer (Ansible)
- Kubernetes cluster initialization
- Addon deployment (CNI, ingress, monitoring)
- Security configuration
- User management setup

## Components

### Terraform Modules
- `twinbox/terraform/main.tf`: Core infrastructure provisioning
- `twinbox/terraform/talos-vm/main.tf`: Talos-specific VM provisioning

### Ansible Roles
- `prerequisites`: Base system preparation
- `container_runtime`: Container runtime setup
- `kubeadm_setup`: Kubernetes cluster initialization
- `cni_install`: CNI plugin installation
- `addons`: Additional cluster components
- `monitoring`: Monitoring stack deployment
- `security`: Security hardening and RBAC
- `user_management`: Identity and access management

### Scripts
- `twinbox/scripts/deploy.sh`: Standard Kubernetes deployment
- `twinbox/scripts/deploy-talos-cluster.sh`: Talos Linux deployment
- `twinbox/scripts/validate-installation.sh`: Post-deployment validation
- `twinbox/scripts/proxmox-talos-helper.sh`: Proxmox-Talos integration utilities

### Tests
- `twinbox/tests/`: Various validation and integration tests
- `twinbox/tests/validate-talos-cluster.sh`: Talos cluster validation
- `twinbox/tests/integration-test-talos.sh`: Talos integration tests

## Configuration

Customize your deployment by modifying:

- Terraform variables in `twinbox/terraform/*.tfvars`
- Ansible group variables in `twinbox/ansible/group_vars/all.yml`
- Machine configuration templates in `twinbox/configs/`

## Documentation

- [Getting Started](twinbox/docs/getting-started.md)
- [Architecture](twinbox/docs/architecture.md)
- [Configuration](twinbox/docs/configuration.md)
- [Talos Integration](twinbox/docs/talos-integration.md)
- [Troubleshooting](twinbox/docs/troubleshooting.md)
- [Verification](twinbox/docs/verification.md)

## Contributing

We welcome contributions to Twinbox! Please see our contributing guidelines for more information.

## License

Twinbox is released under the [LICENSE](twinbox/LICENSE) license.
