#!/bin/bash
# tests/talos-testing-scripts-validation.sh
set -e

echo "Testing Talos testing scripts exist..."
if [ ! -f "twinbox/tests/validate-talos-cluster.sh" ]; then
    echo "FAIL: twinbox/tests/validate-talos-cluster.sh does not exist"
    exit 1
fi

if [ ! -f "twinbox/tests/integration-test-talos.sh" ]; then
    echo "FAIL: twinbox/tests/integration-test-talos.sh does not exist"
    exit 1
fi

echo "PASS: Talos testing scripts exist"