# Getting Started with Twinbox

Welcome to Twinbox, an automated framework for deploying production-ready Kubernetes clusters on Proxmox environments. This guide will walk you through the complete setup process from prerequisites to a fully operational cluster.

## Prerequisites

Before starting with Twinbox, ensure you have the following prerequisites installed:

- Proxmox VE 7.0+
- Terraform v1.0+
- Ansible 2.10+
- kubectl
- SSH access to Proxmox host
- An Ubuntu template VM prepared in Proxmox

## Prerequisites Setup

### Prepare Ubuntu Template VM in Proxmox

Before deploying Twinbox, you need to create an Ubuntu template VM in Proxmox:

1. Create a new VM in Proxmox with Ubuntu OS
2. Install and configure SSH server
3. Set up a user account (typically 'ubuntu') with sudo privileges
4. Upload your SSH public key to the VM
5. Shutdown the VM and convert it to a template
6. Note the template name for use in configuration

### Install Required Tools

On your workstation (the machine where you'll run Twinbox):

```bash
# Install Terraform (https://developer.hashicorp.com/terraform/downloads)
# Install Ansible (https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html)
# Install kubectl (https://kubernetes.io/docs/tasks/tools/)
```

## Quick Start

### 1. Clone the Repository

```bash
git clone https://github.com/your-org/twinbox.git
cd twinbox
```

### 2. Configure Proxmox Connection

Create `terraform/terraform.tfvars` with your Proxmox connection details:

```hcl
proxmox_api_url = "https://your-proxmox-host:8006/api2/json"
proxmox_user = "root@pam"
proxmox_password = "your-password"
target_node = "pve"
vm_template = "ubuntu-template"
```

### 3. Customize Cluster Configuration (Optional)

Review and customize the default settings in `terraform/variables.tf`:

```hcl
cluster_name    = "my-cluster"
master_count    = 1
worker_count    = 2
master_cores    = 2
master_memory   = 4096
worker_cores    = 4
worker_memory   = 8192
```

### 4. Run the Deployment Script

Execute the deployment script:

```bash
./scripts/deploy.sh
```

The script will:
1. Validate prerequisites
2. Plan and apply infrastructure with Terraform
3. Generate Ansible inventory from Terraform outputs
4. Configure the Kubernetes cluster with Ansible
5. Deploy addons and services
6. Set up kubectl access

## Understanding the Deployment Process

### Phase 1: Infrastructure Provisioning
1. Terraform creates VMs on Proxmox based on your configuration
2. VMs are configured with appropriate resources (CPU, RAM, storage)
3. Network connectivity is established

### Phase 2: Cluster Configuration
1. Ansible connects to the provisioned VMs
2. Kubernetes prerequisites are installed
3. Container runtime (containerd) is configured
4. Kubeadm initializes the cluster
5. CNI plugin is installed for networking
6. Addons and monitoring components are deployed

## Post-Deployment Tasks

After successful deployment, verify and access your cluster:

### 1. Verify Cluster Health

```bash
kubectl get nodes
kubectl get pods --all-namespaces
```

### 2. Access Dashboard and Services

```bash
kubectl proxy
# Visit: http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https-kubernetes-dashboard:/proxy/
```

### 3. Access Monitoring

Monitor your cluster through the exposed Grafana service:
- Find the Grafana LoadBalancer IP: `kubectl get svc grafana -n monitoring`
- Access Grafana at `http://<LOADBALANCER_IP>:80`
- Default credentials: admin/admin123 (change after first login)

### 4. Access Identity Management

Authentik provides identity management for your cluster:
- Find the Authentik LoadBalancer IP: `kubectl get svc authentik -n authentik`
- Access Authentik at `http://<LOADBALANCER_IP>:9000`

## Next Steps

### Customize Your Cluster
- Adjust resource allocations in `terraform/variables.tf`
- Change Kubernetes version in `ansible/group_vars/all.yml`
- Select different CNI plugin (calico or cilium)

### Deploy Applications
- Create namespaces for your applications
- Set up ingress routes for external access
- Configure persistent storage

### Set Up Monitoring and Alerts
- Configure alerting rules in Prometheus
- Set up notification channels in AlertManager
- Create custom dashboards in Grafana

### Configure Backup Strategies
- Implement cluster backup procedures
- Set up etcd backup schedules
- Configure application backup strategies

## Troubleshooting

If you encounter issues during deployment:

1. Check the troubleshooting guide: [troubleshooting.md](troubleshooting.md)
2. Review Terraform state: `cd terraform && terraform show`
3. Examine Ansible logs for detailed error messages
4. Verify VM connectivity in Proxmox UI

For more information, see our complete documentation in the [docs](../docs/) directory.

## Prerequisites

Before starting with Twinbox, ensure you have the following prerequisites installed:

- Proxmox VE 7.0+
- Terraform v1.0+
- Ansible 2.10+
- kubectl
- SSH access to Proxmox host
- An Ubuntu template VM prepared in Proxmox

## Quick Start

1. Clone the Twinbox repository:
   ```bash
   git clone https://github.com/your-org/twinbox.git
   cd twinbox
   ```

2. Configure your Proxmox connection details by creating `terraform/terraform.tfvars`:
   ```hcl
   proxmox_api_url = "https://your-proxmox-host:8006/api2/json"
   proxmox_user = "root@pam"
   proxmox_password = "your-password"
   target_node = "pve"
   vm_template = "ubuntu-template"
   ```

3. Run the deployment script:
   ```bash
   ./scripts/deploy.sh
   ```

4. Follow the prompts to confirm the infrastructure plan and complete the deployment.

## Accessing Your Cluster

Once deployment is complete, you can access your cluster using kubectl:

```bash
kubectl get nodes
kubectl get pods --all-namespaces
```

## What's Included

Your Twinbox deployment includes:

- A production-ready Kubernetes cluster
- Calico CNI for networking
- MetalLB for load balancing
- NGINX Ingress Controller
- Prometheus, Grafana, and AlertManager for monitoring
- Authentik for identity management
- RBAC and network policies for security

## Deployment Process

Twinbox follows a two-stage deployment process:

### Stage 1: Infrastructure Provisioning
1. Terraform creates VMs on Proxmox based on your configuration
2. VMs are configured with appropriate resources (CPU, RAM, storage)
3. Network connectivity is established

### Stage 2: Kubernetes Configuration
1. Ansible connects to the provisioned VMs
2. Kubernetes prerequisites are installed
3. Container runtime (containerd) is configured
4. Kubeadm initializes the cluster
5. CNI plugin is installed for networking
6. Addons and monitoring components are deployed

## Post-Deployment Tasks

After successful deployment, you should:

1. Verify cluster health:
   ```bash
   kubectl get nodes
   kubectl get pods --all-namespaces
   ```

2. Access the dashboard (if deployed):
   ```bash
   kubectl proxy
   # Then visit: http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https-kubernetes-dashboard:/proxy/
   ```

3. Set up monitoring endpoints and configure alerts

4. Configure backup and disaster recovery procedures

## Next Steps

- Customize your cluster configuration
- Deploy applications to your cluster
- Set up monitoring and alerting rules
- Configure backup strategies
- Implement CI/CD pipelines for your applications