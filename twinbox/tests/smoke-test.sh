#!/bin/bash
# Smoke test to verify basic cluster functionality

set -e

echo "Running smoke test..."

# Test 1: Check if kubectl is accessible
if ! command -v kubectl &> /dev/null; then
    echo "FAIL: kubectl is not installed or not in PATH"
    exit 1
fi

# Test 2: Check if cluster is responsive
echo "Checking cluster status..."
kubectl cluster-info || { echo "FAIL: Cannot connect to cluster"; exit 1; }

# Test 3: Check node status
NODE_COUNT=$(kubectl get nodes --no-headers | wc -l)
if [ "$NODE_COUNT" -eq 0 ]; then
    echo "FAIL: No nodes found in cluster"
    exit 1
fi

READY_NODES=$(kubectl get nodes --no-headers | grep -c Ready)
if [ "$READY_NODES" -ne "$NODE_COUNT" ]; then
    echo "FAIL: Not all nodes are ready ($READY_NODES/$NODE_COUNT ready)"
    exit 1
fi

echo "PASS: All $NODE_COUNT nodes are ready"

# Test 4: Check system pods
SYSTEM_PODS=$(kubectl get pods -n kube-system --no-headers | wc -l)
READY_SYSTEM_PODS=$(kubectl get pods -n kube-system --no-headers | grep -c Running)

if [ "$READY_SYSTEM_PODS" -lt $(("$SYSTEM_PODS" - 2)) ]; then  # Allow 2 failed pods max
    echo "WARN: Not all system pods are running ($READY_SYSTEM_PODS/$SYSTEM_PODS running)"
else
    echo "PASS: System pods are running"
fi

# Test 5: Deploy a test pod
echo "Deploying test pod..."
kubectl run test-pod --image=nginx:latest --restart=Never --rm -it --image-pull-policy=IfNotPresent --overrides='{"apiVersion":"v1", "spec":{"nodeName":"'"$(kubectl get nodes --no-headers -o jsonpath='{.items[0].metadata.name}')"'}}' -- sleep 5 || { echo "FAIL: Could not deploy test pod"; exit 1; }

echo "PASS: Test pod deployed successfully"

echo "All smoke tests passed!"