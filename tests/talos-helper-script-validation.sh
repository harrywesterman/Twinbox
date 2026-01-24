#!/bin/bash
# tests/talos-helper-script-validation.sh
set -e

echo "Testing Talos helper script exists..."
if [ ! -f "twinbox/scripts/proxmox-talos-helper.sh" ]; then
    echo "FAIL: twinbox/scripts/proxmox-talos-helper.sh does not exist"
    exit 1
fi

if [ ! -x "twinbox/scripts/proxmox-talos-helper.sh" ]; then
    echo "FAIL: twinbox/scripts/proxmox-talos-helper.sh is not executable"
    exit 1
fi

echo "PASS: Talos helper script exists and is executable"