#!/bin/bash
set -e

# Apply Headlamp App
kubectl apply -f ../k8s/apps/headlamp.yaml

echo "Headlamp application created in ArgoCD."
