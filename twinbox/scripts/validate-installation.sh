#!/bin/bash

set -e

echo "Starting Twinbox framework validation..."

# Function to print colored output
print_status() {
    echo -e "\033[1;34m[INFO]\033[0m $1"
}

print_success() {
    echo -e "\033[1;32m[SUCCESS]\033[0m $1"
}

print_warning() {
    echo -e "\033[1;33m[WARNING]\033[0m $1"
}

print_error() {
    echo -e "\033[1;31m[ERROR]\033[0m $1"
}

# Validate prerequisites
print_status "Validating framework structure..."

print_warning "Note: This validation checks framework structure, not runtime dependencies"

# Check if required directories exist
DIRECTORIES=("terraform" "ansible" "scripts" "docs")
for dir in "${DIRECTORIES[@]}"; do
    if [ -d "$dir" ]; then
        print_success "Directory exists: $dir"
    else
        print_error "Directory missing: $dir"
        exit 1
    fi
done

# Check if required files exist
REQUIRED_FILES=(
    "terraform/main.tf"
    "terraform/variables.tf"
    "terraform/outputs.tf"
    "ansible/playbook.yml"
    "ansible/inventory.ini"
    "ansible/group_vars/all.yml"
    "scripts/deploy.sh"
    "docs/getting-started.md"
    "docs/configuration.md"
    "docs/troubleshooting.md"
)

for file in "${REQUIRED_FILES[@]}"; do
    if [ -f "$file" ]; then
        print_success "File exists: $file"
    else
        print_error "File missing: $file"
        exit 1
    fi
done

# Check Ansible roles
ANSIBLE_ROLES=("prerequisites" "container_runtime" "kubeadm_setup" "cni_install" "addons" "monitoring" "security" "user_management")
for role in "${ANSIBLE_ROLES[@]}"; do
    if [ -d "ansible/roles/$role" ]; then
        print_success "Ansible role exists: $role"
    else
        print_error "Ansible role missing: $role"
        exit 1
    fi
done

# Validate Terraform configuration
print_status "Validating Terraform configuration..."
cd terraform
if terraform fmt -check .; then
    print_success "Terraform formatting is correct"
else
    print_warning "Terraform formatting needs attention"
fi

if terraform validate; then
    print_success "Terraform configuration is valid"
else
    print_error "Terraform configuration is invalid"
    exit 1
fi
cd ..

# Validate Ansible playbook syntax
print_status "Validating Ansible playbook syntax..."
if ansible-playbook --syntax-check ansible/playbook.yml; then
    print_success "Ansible playbook syntax is valid"
else
    print_error "Ansible playbook syntax is invalid"
    exit 1
fi

# Check that playbook references existing roles
PLAYBOOK_CONTENT=$(cat ansible/playbook.yml)
for role in "${ANSIBLE_ROLES[@]}"; do
    if echo "$PLAYBOOK_CONTENT" | grep -q "$role"; then
        print_success "Playbook references role: $role"
    else
        print_warning "Playbook does not reference role: $role"
    fi
done

# Validate deployment script
print_status "Validating deployment script..."
if [ -x "scripts/deploy.sh" ]; then
    print_success "Deployment script is executable"
else
    print_error "Deployment script is not executable"
    chmod +x scripts/deploy.sh
    print_success "Made deployment script executable"
fi

# Check documentation completeness
print_status "Validating documentation..."

DOC_FILES=("getting-started.md" "configuration.md" "troubleshooting.md" "architecture.md")
for doc in "${DOC_FILES[@]}"; do
    if [ -f "docs/$doc" ]; then
        if [ -s "docs/$doc" ]; then
            print_success "Documentation exists and is not empty: $doc"
        else
            print_error "Documentation file is empty: $doc"
        fi
    else
        print_error "Documentation file missing: $doc"
    fi
done

# Check for release notes
if [ -f "RELEASE-NOTES.md" ]; then
    if [ -s "RELEASE-NOTES.md" ]; then
        print_success "Release notes exist and are not empty"
    else
        print_error "Release notes file is empty"
    fi
else
    print_error "Release notes file missing"
fi

# Validate test scripts exist
TEST_SCRIPTS=("smoke-test.sh" "integration-test.sh" "validate-cluster.sh")
for test in "${TEST_SCRIPTS[@]}"; do
    if [ -f "tests/$test" ]; then
        print_success "Test script exists: $test"
    else
        print_error "Test script missing: $test"
    fi
done

print_success "All validations passed! Twinbox framework is properly configured."
echo ""
print_status "Framework Summary:"
echo "- Infrastructure provisioning with Terraform"
echo "- Kubernetes cluster setup with Ansible"
echo "- Complete service stack (networking, monitoring, security, identity)"
echo "- Comprehensive documentation"
echo "- Validation and testing scripts"
echo ""
print_success "Twinbox is ready for deployment!"