#!/bin/bash
set -e

# Apply Traefik App
kubectl apply -f ../k8s/apps/traefik.yaml

echo "Traefik application created in ArgoCD."
