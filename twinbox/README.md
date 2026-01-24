# Twinbox - Kubernetes on Proxmox Framework

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

An automated framework for deploying production-ready Kubernetes clusters on Proxmox environments.

## 🚀 Features

- **Automated Infrastructure**: Terraform-based VM provisioning on Proxmox
- **Kubernetes Orchestration**: Complete cluster setup with Ansible
- **Production Ready**: Security-hardened, monitored, and scalable
- **Modular Design**: Separate infrastructure and configuration layers
- **Comprehensive Stack**: Includes networking, load balancing, monitoring, and identity

## 📋 Prerequisites

- Proxmox VE 7.0+
- Terraform v1.0+
- Ansible 2.10+
- kubectl
- SSH access to Proxmox host
- Ubuntu template VM prepared in Proxmox

## 🛠️ Quick Start

1. **Clone the repository:**
   ```bash
   git clone https://github.com/your-org/twinbox.git
   cd twinbox
   ```

2. **Configure your environment:**
   Create `terraform/terraform.tfvars`:
   ```hcl
   proxmox_api_url = "https://your-proxmox-host:8006/api2/json"
   proxmox_user = "root@pam"
   proxmox_password = "your-password"
   target_node = "pve"
   vm_template = "ubuntu-template"
   ```

3. **Deploy the cluster:**
   ```bash
   ./scripts/deploy.sh
   ```

## 🏗️ Architecture

Twinbox follows a two-layer architecture:

### Infrastructure Layer (Terraform)
- VM provisioning and resource allocation
- Network configuration and connectivity
- Storage management

### Configuration Layer (Ansible)
- Kubernetes cluster initialization
- Container runtime setup
- Service deployment and configuration
- Security hardening

## 📚 Documentation

- [Getting Started](docs/getting-started.md) - Step-by-step deployment guide
- [Configuration Guide](docs/configuration.md) - Detailed configuration options
- [Architecture](docs/architecture.md) - Technical architecture overview
- [Troubleshooting](docs/troubleshooting.md) - Common issues and solutions
- [Release Notes](RELEASE-NOTES.md) - Version information and features

## 🧩 Components

### Core Services
- **Kubernetes**: v1.28+ with kubeadm setup
- **Container Runtime**: containerd
- **CNI Plugin**: Calico (with Cilium support)
- **Load Balancer**: MetalLB
- **Ingress Controller**: NGINX Ingress Controller

### Observability
- **Monitoring**: Prometheus stack (Prometheus, Grafana, AlertManager)
- **Metrics**: Node exporter for system metrics
- **Dashboards**: Preconfigured monitoring dashboards

### Security & Identity
- **RBAC**: Role-based access control
- **Network Policies**: Traffic isolation
- **Identity**: Authentik for authentication

## ⚙️ Configuration

### Terraform Variables
Adjust infrastructure settings in `terraform/variables.tf` or override in `terraform/terraform.tfvars`:

```hcl
cluster_name    = "my-cluster"
master_count    = 1
worker_count    = 2
master_cores    = 2
master_memory   = 4096
worker_cores    = 4
worker_memory   = 8192
```

### Ansible Variables
Adjust cluster settings in `ansible/group_vars/all.yml`:

```yaml
kubernetes_version: "v1.28.0"
container_runtime: "containerd"
cni_plugin: "calico"
pod_network_cidr: "192.168.0.0/16"
```

## 🔧 Validation

Validate the framework before deployment:

```bash
./scripts/validate-installation.sh
```

## 🤝 Contributing

We welcome contributions! Please see our [contributing guidelines](CONTRIBUTING.md) for details.

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🆘 Support

- **Issues**: Use GitHub Issues for bug reports and feature requests
- **Documentation**: Comprehensive guides in the `docs/` directory
- **Community**: Join our community forums

---

**Twinbox** - Making Kubernetes on Proxmox simple, reliable, and production-ready.