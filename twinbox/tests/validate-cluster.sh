#!/bin/bash
# Validation script to check cluster components

set -e

echo "Validating cluster components..."

# Check if essential services are running
ESSENTIAL_NAMESPACES=("kube-system" "monitoring" "authentik")
for ns in "${ESSENTIAL_NAMESPACES[@]}"; do
    if kubectl get namespace "$ns" &>/dev/null; then
        echo "PASS: Namespace $ns exists"
    else
        echo "FAIL: Namespace $ns does not exist"
        exit 1
    fi
done

# Check if essential pods are running
ESSENTIAL_LABELS=(
    "component=etcd"
    "component=kube-apiserver" 
    "component=kube-controller-manager"
    "component=kube-scheduler"
    "k8s-app=kube-dns"
    "app=prometheus"
    "app=alertmanager"
    "app.kubernetes.io/name=grafana"
    "app=authentik-server"
)

for label in "${ESSENTIAL_LABELS[@]}"; do
    NAMESPACE="kube-system"
    if [[ "$label" == *"prometheus"* ]] || [[ "$label" == *"alertmanager"* ]] || [[ "$label" == *"grafana"* ]]; then
        NAMESPACE="monitoring"
    elif [[ "$label" == *"authentik"* ]]; then
        NAMESPACE="authentik"
    fi
    
    COUNT=$(kubectl get pods -n "$NAMESPACE" -l "$label" --no-headers 2>/dev/null | wc -l)
    READY=$(kubectl get pods -n "$NAMESPACE" -l "$label" --no-headers 2>/dev/null | grep -c Running)
    
    if [ "$COUNT" -gt 0 ] && [ "$READY" -eq "$COUNT" ]; then
        echo "PASS: All pods with label '$label' in namespace '$NAMESPACE' are running ($READY/$COUNT)"
    else
        echo "FAIL: Not all pods with label '$label' in namespace '$NAMESPACE' are running ($READY/$COUNT)"
    fi
done

# Check if LoadBalancer services have IPs assigned
LOADBALANCER_SVCS=$(kubectl get svc --all-namespaces -o json | jq -r '.items[] | select(.spec.type=="LoadBalancer") | .metadata.namespace + "/" + .metadata.name')
for svc in $LOADBALANCER_SVCS; do
    NS=$(echo "$svc" | cut -d'/' -f1)
    NAME=$(echo "$svc" | cut -d'/' -f2)
    EXTERNAL_IP=$(kubectl get svc "$NAME" -n "$NS" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    if [ -n "$EXTERNAL_IP" ]; then
        echo "PASS: Service $svc has external IP $EXTERNAL_IP"
    else
        echo "INFO: Service $svc does not yet have an external IP (still provisioning)"
    fi
done

echo "Cluster validation complete!"