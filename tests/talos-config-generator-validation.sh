#!/bin/bash
# tests/talos-config-generator-validation.sh
set -e

echo "Testing Talos config generator exists..."
if [ ! -f "twinbox/scripts/generate-talos-config.sh" ]; then
    echo "FAIL: twinbox/scripts/generate-talos-config.sh does not exist"
    exit 1
fi

if [ ! -x "twinbox/scripts/generate-talos-config.sh" ]; then
    echo "FAIL: twinbox/scripts/generate-talos-config.sh is not executable"
    exit 1
fi

if [ ! -f "twinbox/configs/talos-controlplane-template.yaml" ]; then
    echo "FAIL: twinbox/configs/talos-controlplane-template.yaml does not exist"
    exit 1
fi

if [ ! -f "twinbox/configs/talos-worker-template.yaml" ]; then
    echo "FAIL: twinbox/configs/talos-worker-template.yaml does not exist"
    exit 1
fi

echo "PASS: Talos config generator and templates exist"