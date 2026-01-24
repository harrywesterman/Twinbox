#!/bin/bash
# tests/talos-documentation-validation.sh
set -e

echo "Testing Talos documentation exists..."
if [ ! -f "twinbox/docs/talos-integration.md" ]; then
    echo "FAIL: twinbox/docs/talos-integration.md does not exist"
    exit 1
fi

echo "PASS: Talos documentation exists"