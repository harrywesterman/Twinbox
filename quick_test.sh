#!/bin/bash
# Quick test runner - installs dependencies and runs tests

set -e

cd /home/harry/Twinbox

echo "=========================================="
echo "  Twinbox Test Suite - Quick Start"
echo "=========================================="
echo ""

# Check if dependencies are installed
echo "Checking dependencies..."
if ! python3 -c "import pytest" 2>/dev/null; then
    echo "Installing test dependencies..."
    pip3 install -r requirements-test.txt
    echo ""
fi

# Run the tests
echo "Running tests..."
echo "-------------------------------------------"
python3 run_tests.py "$@"
