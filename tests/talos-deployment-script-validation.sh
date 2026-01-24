#!/bin/bash
# tests/talos-deployment-script-validation.sh
set -e

echo "Testing Talos deployment script exists..."
if [ ! -f "twinbox/scripts/deploy-talos-cluster.sh" ]; then
    echo "FAIL: twinbox/scripts/deploy-talos-cluster.sh does not exist"
    exit 1
fi

if [ ! -x "twinbox/scripts/deploy-talos-cluster.sh" ]; then
    echo "FAIL: twinbox/scripts/deploy-talos-cluster.sh is not executable"
    exit 1
fi

echo "PASS: Talos deployment script exists and is executable"