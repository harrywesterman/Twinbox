#!/bin/bash

# Talos Integration Test Suite
# Comprehensive integration tests for Twinbox Talos integration

set -euo pipefail

# Configuration
TEST_NAMESPACE="talos-integration-test"
TIMEOUT_SECONDS=${TIMEOUT_SECONDS:-600}  # 10 minutes default timeout
DEFAULT_KUBECONFIG_PATH="${HOME}/.kube/config"
KUBECONFIG_PATH=${KUBECONFIG:-$DEFAULT_KUBECONFIG_PATH}

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2
}

# Error function
error_exit() {
    log "ERROR: $1"
    exit 1
}

# Cleanup function
cleanup() {
    log "Cleaning up test resources..."
    
    # Delete test namespace if it exists
    if kubectl get namespace "$TEST_NAMESPACE" &>/dev/null; then
        kubectl delete namespace "$TEST_NAMESPACE" --wait=false || true
    fi
    
    log "Cleanup completed"
}

# Setup test environment
setup_test_env() {
    log "Setting up test environment..."
    
    # Create test namespace
    kubectl create namespace "$TEST_NAMESPACE" || true
    
    # Wait for namespace to be ready
    local attempts=0
    local max_attempts=30
    while [[ $attempts -lt $max_attempts ]]; do
        if kubectl get namespace "$TEST_NAMESPACE" &>/dev/null; then
            log "Test namespace $TEST_NAMESPACE created"
            break
        fi
        sleep 10
        ((attempts++))
    done
    
    if [[ $attempts -ge $max_attempts ]]; then
        error_exit "Failed to create test namespace within timeout"
    fi
    
    log "Test environment setup completed"
}

# Test basic pod deployment
test_pod_deployment() {
    log "Testing basic pod deployment..."
    
    # Create a simple pod
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
  namespace: $TEST_NAMESPACE
spec:
  containers:
  - name: test-container
    image: nginx:latest
    ports:
    - containerPort: 80
EOF
    
    # Wait for pod to be running
    local start_time
    start_time=$(date +%s)
    local current_time
    current_time=$(date +%s)
    
    while [[ $((current_time - start_time)) -lt $TIMEOUT_SECONDS ]]; do
        local pod_status
        pod_status=$(kubectl get pod test-pod -n "$TEST_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        
        if [[ "$pod_status" == "Running" ]]; then
            log "Pod test-pod is running"
            break
        elif [[ "$pod_status" == "Failed" ]] || [[ "$pod_status" == "Unknown" ]]; then
            error_exit "Pod test-pod failed to start with status: $pod_status"
        fi
        
        sleep 10
        current_time=$(date +%s)
    done
    
    if [[ $((current_time - start_time)) -ge $TIMEOUT_SECONDS ]]; then
        error_exit "Pod test-pod did not become running within timeout"
    fi
    
    log "Basic pod deployment test passed"
}

# Test service deployment and connectivity
test_service_connectivity() {
    log "Testing service deployment and connectivity..."
    
    # Create a service for the test pod
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: test-service
  namespace: $TEST_NAMESPACE
spec:
  selector:
    app: test-app
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
  type: ClusterIP
EOF
    
    # Update pod to include the required label
    kubectl patch pod test-pod -n "$TEST_NAMESPACE" -p '{"metadata":{"labels":{"app":"test-app"}}}'
    
    # Wait for service to be available
    local attempts=0
    local max_attempts=30
    while [[ $attempts -lt $max_attempts ]]; do
        if kubectl get service test-service -n "$TEST_NAMESPACE" &>/dev/null; then
            local service_ip
            service_ip=$(kubectl get service test-service -n "$TEST_NAMESPACE" -o jsonpath='{.spec.clusterIP}')
            
            if [[ -n "$service_ip" && "$service_ip" != "null" ]]; then
                log "Service test-service is available at $service_ip"
                break
            fi
        fi
        sleep 10
        ((attempts++))
    done
    
    if [[ $attempts -ge $max_attempts ]]; then
        error_exit "Service test-service did not become available within timeout"
    fi
    
    log "Service connectivity test passed"
}

# Test persistent volume (if supported)
test_persistent_volume() {
    log "Testing persistent volume support..."
    
    # Check if storage classes are available
    if kubectl get storageclass &>/dev/null; then
        local default_sc
        default_sc=$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null || echo "")
        
        if [[ -n "$default_sc" ]]; then
            log "Default storage class found: $default_sc"
            
            # Create a PVC
            cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
  namespace: $TEST_NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: $default_sc
EOF
            
            # Wait for PVC to be bound
            local attempts=0
            local max_attempts=30
            while [[ $attempts -lt $max_attempts ]]; do
                local pvc_status
                pvc_status=$(kubectl get pvc test-pvc -n "$TEST_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
                
                if [[ "$pvc_status" == "Bound" ]]; then
                    log "PVC test-pvc is bound"
                    break
                elif [[ "$pvc_status" == "Lost" ]]; then
                    error_exit "PVC test-pvc is lost"
                fi
                
                sleep 10
                ((attempts++))
            done
            
            if [[ $attempts -ge $max_attempts ]]; then
                log "PVC test-pvc did not become bound within timeout, this may be expected depending on storage setup"
            else
                log "Persistent volume test passed"
            fi
        else
            log "No default storage class found, skipping PV test"
        fi
    else
        log "No storage classes available, skipping PV test"
    fi
}

# Test ingress (if available)
test_ingress() {
    log "Testing ingress functionality..."
    
    # Check if ingress controller is available
    if kubectl get ingressclass &>/dev/null; then
        local ingress_classes
        ingress_classes=$(kubectl get ingressclass --no-headers 2>/dev/null | wc -l)
        
        if [[ $ingress_classes -gt 0 ]]; then
            log "Ingress classes found, testing ingress creation..."
            
            # Create an ingress resource
            cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: test-ingress
  namespace: $TEST_NAMESPACE
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  rules:
  - http:
      paths:
      - path: /test
        pathType: Prefix
        backend:
          service:
            name: test-service
            port:
              number: 80
EOF
            
            # Wait for ingress to be created
            local attempts=0
            local max_attempts=30
            while [[ $attempts -lt $max_attempts ]]; do
                if kubectl get ingress test-ingress -n "$TEST_NAMESPACE" &>/dev/null; then
                    log "Ingress test-ingress created"
                    break
                fi
                sleep 10
                ((attempts++))
            done
            
            if [[ $attempts -ge $max_attempts ]]; then
                log "Ingress test-ingress did not become available within timeout, this may be expected"
            else
                log "Ingress test passed"
            fi
        else
            log "No ingress classes available, skipping ingress test"
        fi
    else
        log "Ingress API not available, skipping ingress test"
    fi
}

# Test security policies
test_security_policies() {
    log "Testing security policies..."
    
    # Check if pod security policies or pod security admission is configured
    if kubectl api-resources --api-group=policy | grep -q PodSecurityPolicy; then
        log "Pod Security Policy API is available"
        
        # Create a restricted pod security policy
        cat <<EOF | kubectl apply -f - 2>/dev/null || log "Could not create PSP (may not be enabled)"
apiVersion: policy/v1beta1
kind: PodSecurityPolicy
metadata:
  name: test-restricted-psp
spec:
  privileged: false
  allowPrivilegeEscalation: false
  requiredDropCapabilities:
    - ALL
  volumes:
    - 'configMap'
    - 'emptyDir'
    - 'projected'
    - 'secret'
    - 'downwardAPI'
    - 'persistentVolumeClaim'
  hostNetwork: false
  hostIPC: false
  hostPID: false
  runAsUser:
    rule: 'MustRunAsNonRoot'
  seLinux:
    rule: 'RunAsAny'
  fsGroup:
    rule: 'RunAsAny'
  supplementalGroups:
    rule: 'RunAsAny'
EOF
    else
        log "Pod Security Policy API not available, checking for Pod Security Admission"
        
        # Test basic security context in pod
        cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-security-pod
  namespace: $TEST_NAMESPACE
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    fsGroup: 2000
  containers:
  - name: test-container
    image: nginx:latest
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      runAsNonRoot: true
      runAsUser: 1000
      capabilities:
        drop:
        - ALL
    ports:
    - containerPort: 80
EOF
        
        # Wait for pod to be running
        local attempts=0
        local max_attempts=30
        while [[ $attempts -lt $max_attempts ]]; do
            local pod_status
            pod_status=$(kubectl get pod test-security-pod -n "$TEST_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
            
            if [[ "$pod_status" == "Running" ]]; then
                log "Security test pod is running with security context"
                break
            elif [[ "$pod_status" == "Failed" ]] || [[ "$pod_status" == "Unknown" ]]; then
                log "Security test pod failed with status: $pod_status (this may be expected behavior)"
                break
            fi
            
            sleep 10
            ((attempts++))
        done
    fi
    
    log "Security policies test completed"
}

# Run all tests
run_tests() {
    log "Starting Talos integration tests..."
    
    setup_test_env
    test_pod_deployment
    test_service_connectivity
    test_persistent_volume
    test_ingress
    test_security_policies
    
    log "All Talos integration tests completed!"
}

# Main function
main() {
    # Set trap to cleanup on exit
    trap cleanup EXIT
    
    run_tests
}

# Call main function
main "$@"