#!/bin/bash
set -e

# Add ArgoCD Helm repo
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# Create namespace
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# Install ArgoCD
helm upgrade --install argo-cd argo/argo-cd \
  --namespace argocd \
  --set server.service.type=LoadBalancer \
  --version 5.45.0

# Wait for deployment
echo "Waiting for ArgoCD server to be ready..."
kubectl wait --for=condition=ready pods -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s

# Get admin password
echo "ArgoCD initial admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
echo
