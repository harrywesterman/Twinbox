#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

echo "Starting Twinbox Kubernetes deployment..."

# Function to print colored output
print_status() {
    echo -e "\033[1;34m[INFO]\033[0m $1"
}

print_success() {
    echo -e "\033[1;32m[SUCCESS]\033[0m $1"
}

print_error() {
    echo -e "\033[1;31m[ERROR]\033[0m $1"
}

# Validate prerequisites
print_status "Validating prerequisites..."
if ! command -v terraform &> /dev/null; then
    print_error "Terraform is not installed"
    exit 1
fi

if ! command -v ansible &> /dev/null; then
    print_error "Ansible is not installed"
    exit 1
fi

if ! command -v kubectl &> /dev/null; then
    print_error "kubectl is not installed"
    exit 1
fi

if [ ! -f "terraform/terraform.tfvars" ]; then
    print_status "Warning: terraform/terraform.tfvars not found, using defaults"
fi

# Initialize Terraform
print_status "Initializing Terraform..."
cd terraform
terraform init

# Plan and apply infrastructure
print_status "Planning infrastructure..."
terraform plan -out=tfplan

echo "Do you want to apply this plan? (yes/no): "
read -r response
if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    print_status "Applying infrastructure..."
    terraform apply tfplan
else
    print_status "Plan not applied. Exiting."
    exit 0
fi

# Get VM IP addresses and update Ansible inventory
print_status "Updating Ansible inventory..."
cd ..

# Generate inventory based on Terraform outputs
print_status "Generating Ansible inventory..."
cat > ansible/inventory.ini << EOF
[k8s_cluster]
$(terraform -chdir=terraform output -raw master_nodes | jq -r 'to_entries[] | "\(.value.name) ansible_host=\(.value.ip_address) ansible_user=ubuntu ansible_ssh_private_key_file=~/.ssh/id_rsa"')
$(terraform -chdir=terraform output -raw worker_nodes | jq -r 'to_entries[] | "\(.value.name) ansible_host=\(.value.ip_address) ansible_user=ubuntu ansible_ssh_private_key_file=~/.ssh/id_rsa"')

[k8s_masters]
$(terraform -chdir=terraform output -raw master_nodes | jq -r 'to_entries[] | "\(.value.name)"')

[k8s_workers]
$(terraform -chdir=terraform output -raw worker_nodes | jq -r 'to_entries[] | "\(.value.name)"')
EOF

# Run Ansible playbook
print_status "Running Ansible playbook..."
cd ansible
ansible-playbook -i inventory.ini playbook.yml

# Copy kubeconfig to home directory
print_status "Setting up kubectl configuration..."
mkdir -p ~/.kube
cp /etc/kubernetes/admin.conf ~/.kube/config
chown $(whoami):$(id -gn $(whoami)) ~/.kube/config
chmod 600 ~/.kube/config

print_success "Deployment completed successfully!"
echo ""
echo "Your Kubernetes cluster is ready!"
echo "Access your cluster with: kubectl get nodes"
echo ""
echo "Services:"
echo "- Grafana: http://<load-balancer-ip>:3000 (admin/admin123)"
echo "- Authentik: http://<load-balancer-ip>:9000"
echo ""
print_success "Check the documentation in twinbox/docs/ for more information."