#!/bin/bash
# tests/readme-talos-update-validation.sh
set -e

echo "Testing README.md includes Talos integration..."
if ! grep -q "Talos" README.md; then
    echo "FAIL: README.md does not mention Talos integration"
    exit 1
fi

echo "PASS: README.md includes Talos integration"