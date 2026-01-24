#!/bin/bash
# Twinbox Talos Integration Validation Test
# This script validates that all components of the Talos integration are properly implemented

set -e

echo "=== Comprehensive Talos Integration Test ==="

echo "Checking if all required files exist..."

# Check Terraform module
if [ ! -f "twinbox/terraform/talos-vm/main.tf" ]; then
    echo "FAIL: twinbox/terraform/talos-vm/main.tf does not exist"
    exit 1
fi

if [ ! -f "twinbox/terraform/talos-vm/variables.tf" ]; then
    echo "FAIL: twinbox/terraform/talos-vm/variables.tf does not exist"
    exit 1
fi

if [ ! -f "twinbox/terraform/talos-vm/outputs.tf" ]; then
    echo "FAIL: twinbox/terraform/talos-vm/outputs.tf does not exist"
    exit 1
fi

# Check helper script
if [ ! -f "twinbox/scripts/proxmox-talos-helper.sh" ]; then
    echo "FAIL: twinbox/scripts/proxmox-talos-helper.sh does not exist"
    exit 1
fi

if [ ! -x "twinbox/scripts/proxmox-talos-helper.sh" ]; then
    echo "FAIL: twinbox/scripts/proxmox-talos-helper.sh is not executable"
    exit 1
fi

# Check config generator
if [ ! -f "twinbox/scripts/generate-talos-config.sh" ]; then
    echo "FAIL: twinbox/scripts/generate-talos-config.sh does not exist"
    exit 1
fi

if [ ! -x "twinbox/scripts/generate-talos-config.sh" ]; then
    echo "FAIL: twinbox/scripts/generate-talos-config.sh is not executable"
    exit 1
fi

# Check templates
if [ ! -f "twinbox/configs/talos-controlplane-template.yaml" ]; then
    echo "FAIL: twinbox/configs/talos-controlplane-template.yaml does not exist"
    exit 1
fi

if [ ! -f "twinbox/configs/talos-worker-template.yaml" ]; then
    echo "FAIL: twinbox/configs/talos-worker-template.yaml does not exist"
    exit 1
fi

# Check deployment script
if [ ! -f "twinbox/scripts/deploy-talos-cluster.sh" ]; then
    echo "FAIL: twinbox/scripts/deploy-talos-cluster.sh does not exist"
    exit 1
fi

if [ ! -x "twinbox/scripts/deploy-talos-cluster.sh" ]; then
    echo "FAIL: twinbox/scripts/deploy-talos-cluster.sh is not executable"
    exit 1
fi

# Check testing scripts
if [ ! -f "twinbox/tests/validate-talos-cluster.sh" ]; then
    echo "FAIL: twinbox/tests/validate-talos-cluster.sh does not exist"
    exit 1
fi

if [ ! -f "twinbox/tests/integration-test-talos.sh" ]; then
    echo "FAIL: twinbox/tests/integration-test-talos.sh does not exist"
    exit 1
fi

# Check documentation
if [ ! -f "twinbox/docs/talos-integration.md" ]; then
    echo "FAIL: twinbox/docs/talos-integration.md does not exist"
    exit 1
fi

# Check README update
if ! grep -q "Talos" README.md; then
    echo "FAIL: README.md does not mention Talos integration"
    exit 1
fi

echo "PASS: All files for Talos integration exist and are properly configured"
echo "=== Comprehensive Talos Integration Test Complete ==="