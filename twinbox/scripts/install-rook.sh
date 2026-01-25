#!/bin/bash
set -e

# Apply Rook Operator App
kubectl apply -f ../k8s/apps/rook-ceph.yaml

# Apply Rook Cluster App
kubectl apply -f ../k8s/apps/rook-ceph-cluster.yaml

echo "Rook applications created in ArgoCD."
