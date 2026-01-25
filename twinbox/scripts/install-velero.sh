#!/bin/bash
set -e

# Apply Velero App
kubectl apply -f ../k8s/apps/velero.yaml

echo "Velero application created in ArgoCD."
