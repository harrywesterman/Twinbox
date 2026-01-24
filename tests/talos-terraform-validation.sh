#!/bin/bash
# tests/talos-terraform-validation.sh
set -e

echo "Testing Talos Terraform module exists..."
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

echo "PASS: All Talos Terraform module files exist"