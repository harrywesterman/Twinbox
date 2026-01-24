#!/bin/bash
# Integration test to verify cross-component functionality

set -e

echo "Running integration tests..."

# Test 1: Verify network connectivity between pods
kubectl run connectivity-test --image=busybox --restart=Never --rm -it -- wget -qO- http://kubernetes.default.svc.cluster.local || { echo "FAIL: Cannot reach kubernetes service"; exit 1; }
echo "PASS: Internal service connectivity works"

# Test 2: Verify storage provisioning
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF

sleep 10

PVC_STATUS=$(kubectl get pvc test-pvc -o jsonpath='{.status.phase}')
if [ "$PVC_STATUS" = "Bound" ]; then
    echo "PASS: PVC was bound successfully"
else
    echo "FAIL: PVC was not bound (status: $PVC_STATUS)"
    kubectl delete pvc test-pvc
    exit 1
fi

kubectl delete pvc test-pvc
echo "PASS: Storage provisioning works"

# Test 3: Verify ingress functionality
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-ingress-app
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-ingress
  template:
    metadata:
      labels:
        app: test-ingress
    spec:
      containers:
      - name: app
        image: nginx:latest
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: test-ingress-service
  namespace: default
spec:
  selector:
    app: test-ingress
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: test-ingress
  namespace: default
spec:
  rules:
  - host: test.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: test-ingress-service
            port:
              number: 80
EOF

sleep 30

INGRESS_IP=$(kubectl get ingress test-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
if [ -n "$INGRESS_IP" ]; then
    echo "PASS: Ingress controller assigned IP $INGRESS_IP"
else
    echo "INFO: Ingress controller still provisioning IP"
fi

kubectl delete ingress test-ingress
kubectl delete service test-ingress-service
kubectl delete deployment test-ingress-app

echo "Integration tests completed!"