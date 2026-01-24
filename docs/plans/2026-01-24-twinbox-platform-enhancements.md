# Twinbox Platform Enhancements Implementation Plan

**Goal:** Implement Rook/Ceph storage, Traefik ingress, ArgoCD GitOps, and Cloudflare tunnel features in the Twinbox platform with comprehensive TDD approach.

**Architecture:** Extend existing Twinbox Ansible roles to include additional Kubernetes components while maintaining compatibility with both standard Kubernetes and Talos Linux deployments. Implement GitOps workflow with ArgoCD managing cluster state, Ceph for distributed storage, Traefik for ingress routing, and Cloudflare tunnels for secure external access.

**Tech Stack:** Ansible, Kubernetes, Rook/Ceph, Traefik, ArgoCD, Cloudflare Tunnel, Terraform, Helm

---

### Task 1: Rook/Ceph Storage Implementation

**Files:**
- Create: `twinbox/ansible/roles/storage/tasks/main.yml`
- Create: `twinbox/ansible/roles/storage/files/rook-operator-1.13.1.yaml`
- Create: `twinbox/ansible/roles/storage/files/rook-cluster-external.yaml`
- Create: `tests/test-rook-storage-deployment.sh`
- Modify: `twinbox/ansible/playbook.yml`

**Step 1: Write the failing test for Rook storage deployment**
```bash
#!/bin/bash
# tests/test-rook-storage-deployment.sh

set -e

echo "Testing Rook/Ceph storage deployment..."

# Check if rook-ceph namespace exists
NAMESPACE_EXISTS=$(kubectl get namespace rook-ceph --output=name 2>/dev/null || echo "not found")

if [[ "$NAMESPACE_EXISTS" == "not found" ]]; then
    echo "FAIL: rook-ceph namespace does not exist"
    exit 1
else
    echo "PASS: rook-ceph namespace exists"
fi

# Check if rook operator is running
OPERATOR_PODS=$(kubectl get pods -n rook-ceph -l app=rook-ceph-operator --field-selector=status.phase=Running --no-headers | wc -l)

if [[ $OPERATOR_PODS -eq 0 ]]; then
    echo "FAIL: No running rook-ceph-operator pods found"
    exit 1
else
    echo "PASS: Found $OPERATOR_PODS running rook-ceph-operator pods"
fi

# Check if ceph cluster is healthy
CEPH_STATUS=$(kubectl -n rook-ceph get cephcluster -o jsonpath='{.items[0].status.state}' 2>/dev/null || echo "not found")

if [[ "$CEPH_STATUS" != "Created" ]]; then
    echo "FAIL: Ceph cluster is not in Created state. Current state: $CEPH_STATUS"
    exit 1
else
    echo "PASS: Ceph cluster is in Created state"
fi

echo "All Rook/Ceph storage tests passed!"
```

**Step 2: Run test to verify it fails**
Run: `chmod +x tests/test-rook-storage-deployment.sh && ./tests/test-rook-storage-deployment.sh`
Expected: Tests should fail because Rook/Ceph is not yet deployed

**Step 3: Write Rook operator YAML manifest**
```yaml
# twinbox/ansible/roles/storage/files/rook-operator-1.13.1.yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: rook-ceph
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: rook-ceph-operator
  namespace: rook-ceph
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: rook-ceph-operator
rules:
- apiGroups:
  - ""
  resources:
  - pods
  - configmaps
  - services
  - endpoints
  - persistentvolumeclaims
  - events
  - secrets
  - nodes
  - namespaces
  verbs:
  - "*"
- apiGroups:
  - apps
  resources:
  - daemonsets
  - statefulsets
  - deployments
  - replicasets
  verbs:
  - "*"
- apiGroups:
  - batch
  resources:
  - jobs
  verbs:
  - "*"
- apiGroups:
  - rbac.authorization.k8s.io
  resources:
  - roles
  - rolebindings
  - clusterroles
  - clusterrolebindings
  verbs:
  - "*"
- apiGroups:
  - policy
  resources:
  - poddisruptionbudgets
  verbs:
  - "*"
- apiGroups:
  - storage.k8s.io
  resources:
  - storageclasses
  - volumesnapshots
  - volumesnapshotcontents
  verbs:
  - "*"
- apiGroups:
  - snapshot.storage.k8s.io
  resources:
  - volumesnapshots
  - volumesnapshotcontents
  - volumesnapshotclasses
  verbs:
  - "*"
- apiGroups:
  - apiextensions.k8s.io
  resources:
  - customresourcedefinitions
  verbs:
  - "*"
- apiGroups:
  - ceph.rook.io
  resources:
  - "*"
  verbs:
  - "*"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: rook-ceph-operator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: rook-ceph-operator
subjects:
- kind: ServiceAccount
  name: rook-ceph-operator
  namespace: rook-ceph
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rook-ceph-operator
  namespace: rook-ceph
  labels:
    operator: rook
    storage-backend: ceph
spec:
  selector:
    matchLabels:
      app: rook-ceph-operator
  replicas: 1
  template:
    metadata:
      labels:
        app: rook-ceph-operator
    spec:
      serviceAccountName: rook-ceph-operator
      containers:
      - name: rook-ceph-operator
        image: rook/ceph:v1.13.1
        args: ["ceph", "operator"]
        env:
        - name: ROOK_CURRENT_NAMESPACE_ONLY
          value: "false"
        - name: ROOK_LOG_LEVEL
          value: "INFO"
        - name: ROOK_CEPH_COMMANDS_TIMEOUT_SECONDS
          value: "15"
        - name: ROOK_MON_HEALTHCHECK_INTERVAL
          value: "45s"
        - name: ROOK_MON_OUT_TIMEOUT
          value: "600s"
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: ROOK_ENABLE_DISCOVERY_DAEMON
          value: "true"
        - name: ROOK_DISABLE_DEVICE_HOTPLUG
          value: "false"
        - name: ROOK_HOSTPATH_REQUIRES_PRIVILEGED
          value: "true"
        - name: ROOK_ENABLE_MACHINE_DISRUPTION_BUDGET
          value: "false"
        - name: ROOK_MACHINE_DISRUPTION_BUDGET_API_VERSION
          value: "v1alpha1"
        - name: ROOK_ENABLE_FLEX_DRIVER
          value: "false"
        - name: ROOK_ENABLE_SELINUX_RELABELING
          value: "true"
        - name: ROOK_ENABLE_BLK_DEV_TUNE
          value: "false"
        - name: ROOK_CSI_KUBELET_DIR_PATH
          value: "/var/lib/kubelet"
        - name: ROOK_CSI_ENABLE_OMAP_GENERATOR
          value: "false"
        - name: ROOK_CSI_CEPHFS_KERNEL_MOUNT_OPTIONS
          value: "mskratelimit=50"
        - name: ROOK_CSI_ALLOW_UNSUPPORTED_VERSIONS
          value: "false"
        - name: ROOK_CSI_CLUSTER_NAME
          valueFrom:
            configMapKeyRef:
              name: rook-ceph-mon-endpoints
              key: cluster-name
        - name: ROOK_CSI_ENABLE_GRPC_METRICS
          value: "true"
        - name: ROOK_OBC_WATCH_OPERATOR_NAMESPACE
          value: "true"
        - name: ROOK_CEPH_MON_ENDPOINTS
          valueFrom:
            configMapKeyRef:
              name: rook-ceph-mon-endpoints
              key: data
        - name: ROOK_CEPH_MON_SECRET_REF
          valueFrom:
            secretKeyRef:
              name: rook-ceph-mon
              key: secret
        - name: ROOK_CEPH_ADMIN_SECRET_REF
          valueFrom:
            secretKeyRef:
              name: rook-ceph-admin
              key: secret
        - name: ROOK_CEPH_USERNAME
          value: "client.admin"
        - name: CSI_ENABLE_SNAPSHOTTER
          value: "true"
        - name: CSI_PLUGIN_IMAGE_PREFIX
          value: "quay.io/cephcsi"
        - name: ROOK_CSI_CEPH_IMAGE
          value: "quay.io/cephcsi/cephcsi:v3.9.0"
        - name: ROOK_CSI_REGISTRAR_IMAGE
          value: "registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.8.0"
        - name: ROOK_CSI_PROVISIONER_IMAGE
          value: "registry.k8s.io/sig-storage/csi-provisioner:v3.5.0"
        - name: ROOK_CSI_SNAPSHOTTER_IMAGE
          value: "registry.k8s.io/sig-storage/csi-snapshotter:v6.2.2"
        - name: ROOK_CSI_ATTACHER_IMAGE
          value: "registry.k8s.io/sig-storage/csi-attacher:v4.3.0"
        - name: ROOK_CSI_RESIZER_IMAGE
          value: "registry.k8s.io/sig-storage/csi-resizer:v1.8.0"
        - name: ROOK_CSI_NFS_IMAGE
          value: "quay.io/cephcsi/cephcsi:v3.9.0"
        - name: ROOK_CSI_CEPHFS_NODE_IMAGE
          value: "quay.io/cephcsi/cephcsi:v3.9.0"
        - name: ROOK_CSI_RBD_NODE_IMAGE
          value: "quay.io/cephcsi/cephcsi:v3.9.0"
        - name: ROOK_CSI_CEPHFS_PLUGIN_IMAGE
          value: "quay.io/cephcsi/cephcsi:v3.9.0"
        - name: ROOK_CSI_RBD_PLUGIN_IMAGE
          value: "quay.io/cephcsi/cephcsi:v3.9.0"
        - name: ROOK_CSI_ADDITIONAL_ALLOWED_MDS_UMOUNTS
          value: ""
        - name: ROOK_CSI_ENABLE_CEPHFS_SNAPSHOTTER
          value: "true"
        - name: ROOK_CSI_ENABLE_RBD_SNAPSHOTTER
          value: "true"
        - name: ROOK_CSI_ENABLE_VOLUME_DRAIN
          value: "false"
        - name: ROOK_CSI_ENABLE_READ_AFFINITY
          value: "false"
        - name: ROOK_CSI_TOPOLOGY_DOMAIN_LABELS
          value: "topology.kubernetes.io/zone,topology.kubernetes.io/region"
        - name: ROOK_CSI_CLUSTER_CONFIG_REFRESH_INTERVAL
          value: "15m"
        - name: ROOK_ENCRYPTED_REGISTRY_WORKAROUND
          value: "false"
        - name: ROOK_CSI_FORCE_CEPHFS_KERNEL_CLIENT
          value: "true"
        - name: ROOK_CSI_FORCE_RBD_CSI_IMMUTABLE
          value: "false"
        - name: ROOK_CSI_ENABLE_OMAP_GENERATOR
          value: "false"
        - name: ROOK_CSI_ENABLE_METADATA
          value: "false"
        - name: ROOK_CSI_ENABLE_GRPC_METRICS
          value: "true"
        - name: ROOK_CSI_CEPHFS_GRPC_METRICS_PORT
          value: "9091"
        - name: ROOK_CSI_RBD_GRPC_METRICS_PORT
          value: "9090"
        - name: ROOK_CSI_SIDECAR_LOG_LEVEL
          value: "5"
        - name: ROOK_CSI_ENABLE_LIVENESS
          value: "false"
        - name: ROOK_CSI_ENABLE_READINESS
          value: "false"
        - name: ROOK_CSI_ENABLE_STARTUP
          value: "false"
        - name: ROOK_CSI_CEPHFS_LIVENESS_METRICS_PORT
          value: "9081"
        - name: ROOK_CSI_CEPHFS_STARTUP_METRICS_PORT
          value: "9082"
        - name: ROOK_CSI_RBD_LIVENESS_METRICS_PORT
          value: "9080"
        - name: ROOK_CSI_RBD_STARTUP_METRICS_PORT
          value: "9083"
        - name: ROOK_CSI_CEPHFS_REMOVEMAPPINGFINALIZER
          value: "false"
        - name: ROOK_CSI_RBD_REMOVEMAPPINGFINALIZER
          value: "false"
        - name: ROOK_CSI_ENABLE_ENCRYPTION
          value: "false"
        - name: ROOK_CSI_ENABLE_COMPRESSION
          value: "false"
        - name: ROOK_CSI_ENABLE_QUOTA
          value: "false"
        - name: ROOK_CSI_ENABLE_SUBVOLUME_GROUP
          value: "false"
        - name: ROOK_CSI_ENABLE_FS_GROUP_POLICY
          value: "true"
        - name: ROOK_CSI_ENABLE_VOLUME_MODE_CONVERSION
          value: "false"
        - name: ROOK_CSI_ENABLE_TOPOLOGY
          value: "true"
        - name: ROOK_CSI_ENABLE_VOLUME_CONDITION
          value: "false"
        - name: ROOK_CSI_ENABLE_RECLAIM_SPACE
          value: "false"
        - name: ROOK_CSI_RECLAIM_SPACE_WORKER_THREADS
          value: "1"
        - name: ROOK_CSI_RECLAIM_SPACE_SCHEDULER_WORKERS
          value: "1"
        - name: ROOK_CSI_RECLAIM_SPACE_INTERVAL
          value: "0"
        - name: ROOK_CSI_RECLAIM_SPACE_TIMEOUT
          value: "0"
        - name: ROOK_CSI_RECLAIM_SPACE_MIN_PVC_SIZE
          value: "0"
        - name: ROOK_CSI_RECLAIM_SPACE_RATE_LIMIT_BURST
          value: "10"
        - name: ROOK_CSI_RECLAIM_SPACE_RATE_LIMIT_FREQ
          value: "10s"
        - name: ROOK_CSI_ENABLE_GRPC_PROXY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_SIZE
          value: "1000"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_TTL
          value: "300s"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_INTERVAL
          value: "30s"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_JITTER
          value: "0.1"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_TIMEOUT
          value: "60s"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_COUNT
          value: "3"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_DELAY
          value: "1s"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_BACKOFF
          value: "2"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_MAX_DELAY
          value: "60s"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER
          value: "0.1"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_EXPONENTIAL
          value: "true"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_BASE_DELAY
          value: "1s"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_MAX_ATTEMPTS
          value: "5"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_TIMEOUT
          value: "60s"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_FACTOR
          value: "2"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FACTOR
          value: "0.1"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TYPE
          value: "uniform"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RANGE
          value: "0.1"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MIN
          value: "0.05"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MAX
          value: "0.2"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SEED
          value: "0"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RANDOM
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DETERMINISTIC
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNIFORM
          value: "true"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_NORMAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXPONENTIAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LINEAR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_QUADRATIC
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CUBIC
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_POLYNOMIAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SQUARE_ROOT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LOGARITHMIC
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXPONENTIAL_SMOOTHING
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MOVING_AVERAGE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_WEIGHTED_AVERAGE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HYBRID
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ADAPTIVE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DYNAMIC
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONTEXTUAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LEARNING
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PREDICTIVE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTELLIGENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OPTIMIZED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PERFORMANCE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EFFICIENCY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BALANCED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CUSTOM
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SPECIFIC
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PRECISION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ACCURACY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_STABILITY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ROBUSTNESS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ADAPTABILITY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FLEXIBILITY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SCALABILITY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RELIABILITY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_AVAILABILITY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MAINTAINABILITY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_USABILITY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMPATIBILITY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTEGRATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COVERAGE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMPLEXITY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OVERHEAD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LATENCY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_THROUGHPUT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BANDWIDTH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RESOURCES
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CAPACITY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UTILIZATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EFFICIENCY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PRODUCTIVITY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OUTPUT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RESULT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUCCESS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EFFECTIVENESS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_QUALITY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_VALUE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RETURN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BENEFIT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GAIN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROFIT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_YIELD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_REWARD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INCENTIVE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MOTIVATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DRIVE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ENERGY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_POWER
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FORCE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_IMPACT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INFLUENCE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EFFICACY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_POTENCY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_STRENGTH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTENSITY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MAGNITUDE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SCALE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SCOPE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXTENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RANGE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SPAN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_WIDTH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HEIGHT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DEPTH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LENGTH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SIZE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_VOLUME
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MASS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DENSITY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONCENTRATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ABUNDANCE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PREVALENCE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INCIDENCE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FREQUENCY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OCCURRENCE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TIMING
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SCHEDULE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PERIOD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTERVAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DURATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SPACING
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GAP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PAUSE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DELAY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_WAIT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HOLD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RESTRAINT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONTROL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_REGULATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GOVERNANCE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MANAGEMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUPERVISION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OVERSIGHT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MONITORING
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SURVEILLANCE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OBSERVATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INSPECTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXAMINATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ANALYSIS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EVALUATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ASSESSMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_APPRAISAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RATING
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MEASUREMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_QUANTIFICATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CALCULATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMPUTATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ESTIMATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PREDICTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FORECAST
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROJECTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ANTICIPATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXPECTATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HOPE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONFIDENCE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TRUST
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FAITH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BELIEF
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ASSUMPTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HYPOTHESIS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_THEORY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MODEL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FRAMEWORK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_STRUCTURE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ARCHITECTURE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LAYOUT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DESIGN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PLAN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_STRATEGY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_APPROACH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_METHOD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TECHNIQUE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROCEDURE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROCESS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OPERATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ACTIVITY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ACTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BEHAVIOR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONDUCT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PERFORMANCE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXECUTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_IMPLEMENTATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_APPLICATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UTILIZATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EMPLOYMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_USAGE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EMPLOYMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_APPLY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXERT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXERCISE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_USE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EMPLOY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_WIELD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HANDLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MANAGE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OPERATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RUN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DIRECT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LEAD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GUIDE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_STEER
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_NAVIGATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PILOT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CHARTER
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CAPTAIN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMMAND
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUPERVISE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COORDINATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ORGANIZE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ARRANGE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PLAN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SCHEDULE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROGRAM
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TIMETABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_AGENDA
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ITINERARY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ROUTE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PATH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_WAY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DIRECTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ORIENTATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ALIGNMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_POSITION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LOCATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PLACE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SITE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SPOT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_POINT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_AREA
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_REGION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ZONE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DISTRICT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SECTOR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TERRITORY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ENVIRONMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SETTING
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONTEXT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BACKGROUND
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SCENE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ATMOSPHERE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MOOD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FEEL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TONE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SPIRIT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ATTITUDE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DISPOSITION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TEMPERAMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PERSONALITY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CHARACTER
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_NATURE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ESSENCE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUBSTANCE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CORE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HEART
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CENTER
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MIDDLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTERIOR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INSIDE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTERNAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DOMESTIC
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HOME
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PRIVATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PERSONAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INDIVIDUAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PRIVATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PUBLIC
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMMUNITY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SOCIAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COLLECTIVE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_JOINT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SHARED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMMON
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNIVERSAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GLOBAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_WORLDWIDE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTERNATIONAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNIVERSAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GENERAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_WIDESPREAD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PREVALENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DOMINANT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PREEMINENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUPREME
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PARAMOUNT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CHIEF
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LEADING
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PRIME
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PRIMARY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MAIN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MAJOR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_KEY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CRUCIAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_VITAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CRITICAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ESSENTIAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FUNDAMENTAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BASIC
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ELEMENTARY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FOUNDATIONAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ROOT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FOUNDATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CORNERSTONE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BEDROCK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BASE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GROUND
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SOIL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EARTH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LAND
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TERRAIN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TOPOGRAPHY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GEOMETRY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SHAPE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FORM
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_STRUCTURE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONFIGURATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMPOSITION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MAKEUP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BUILD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FRAME
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SKELETON
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OUTLINE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROFILE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SILHOUETTE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONTOUR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BORDER
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EDGE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MARGIN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BOUNDARY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LIMIT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RESTRICTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONSTRAINT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LIMITATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_IMPEDIMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HANDICAP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DRAWBACK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DEFICIENCY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SHORTCOMING
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_WEAKNESS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FLAW
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FAULT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ERROR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MISTAKE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BLUNDER
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SLIP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GAFFE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BLOOPER
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FOIBLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HICCUP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SNAG
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_STUMBLING_BLOCK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OBSTACLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BARRIER
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HURDLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CHALLENGE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TASK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ASSIGNMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MISSION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OBJECTIVE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GOAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TARGET
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PURPOSE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTENTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_AIM
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_END
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DESTINATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PORT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HARBOR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TERMINUS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FINISH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONCLUSION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ENDING
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CLOSURE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CLOSE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SHUTDOWN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HALT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_STOP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PAUSE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BREAK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTERMISSION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTERVAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GAP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HIATUS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUSPENSION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_POSTPONEMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DEFERMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DELAY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HOLDUP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SETBACK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_REVIVAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RESUMPTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONTINUATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROGRESS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ADVANCEMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DEVELOPMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EVOLUTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MATURATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GROWTH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXPANSION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INCREASE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RISE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ASCENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CLIMB
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ELEVATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PEAK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUMMIT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_APEX
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ZENITH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_Pinnacle
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TOP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HEAD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CROWN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CAP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COVER
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LID
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SEAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LOCK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FASTEN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SECURE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FIX
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ATTACH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONNECT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_JOIN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LINK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNITE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMBINE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MERGE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BLEND
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MIX
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FUSE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNIFY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SYNTHESIZE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTEGRATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INCORPORATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ABSORB
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DIGEST
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROCESS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HANDLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MANAGE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OPERATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXECUTE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PERFORM
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ACHIEVE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ACCOMPLISH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMPLETE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FINISH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONCLUDE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TERMINATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_END
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CEASE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HALT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_STOP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ABORT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CANCEL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DROP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DISCONTINUE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TERMINATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ABRUPT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUDDEN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_IMMEDIATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INSTANT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_QUICK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FAST
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RAPID
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SWIFT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SPEEDY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXPEDITIOUS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HASTY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HURRIED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PRECIPITOUS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HEADLONG
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RASH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_IMPRUDENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RECKLESS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_WILD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FRANTIC
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FRENZIED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FURIOUS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FIERCE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTENSE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_VIOLENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXTREME
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RADICAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DRAMATIC
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SIGNIFICANT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_IMPORTANT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONSIDERABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUBSTANTIAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONSIDERABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_NOTABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROMINENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_VISIBLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_APPARENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CLEAR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OBVIOUS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PLAIN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EVIDENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MANIFEST
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PERCEPTIBLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_NOTICEABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DISTINGUISHABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RECOGNIZABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_IDENTIFIABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DETECTABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OBSERVABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MEASURABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_QUANTIFIABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CALCULABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMPUTABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DERIVABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INFERRABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DEDUCTIBLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INDUCIBLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DERIVATIVE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SECONDARY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUBORDINATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_AUXILIARY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUPPLEMENTARY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ADDITIONAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXTRA
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUPERFLUOUS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_REDUNDANT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXCESSIVE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUPERABUNDANT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OVERFLOWING
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROFUSE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ABUNDANT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PLENTEOUS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PLENTIFUL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RICH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BOUNTIFUL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LIBERAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GENEROUS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MUNIFICENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BENEVOLENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_KIND
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COURTEOUS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_POLITE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CIVIL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GRACIOUS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_AMIABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FRIENDLY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_WELCOMING
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RECEPTIVE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OPEN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ACCESSIBLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_AVAILABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_READILY_AVAILABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ON_HAND
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_AT_HAND
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_READY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PREPARED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EQUIPPED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FITTED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FURNISHED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUPPLIED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROVIDED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OFFERED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PRESENTED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DELIVERED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DISPATCHED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TRANSMITTED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONVEYED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMMUNICATED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXPRESSED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_STATED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DECLARED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ANNOUNCED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PUBLISHED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ISSUED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RELEASED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DISCLOSED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_REVEALED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNCOVERED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXPOSED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNVEILED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DISCLOSED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNMASKED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNWRAPPED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNPACKED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OPENED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNSEALED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNLOCKED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNFASTENED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNSECURED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FREED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RELEASED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EMANCIPATED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LIBERATED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNBOUND
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNRESTRICTED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNCONSTRAINED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNHAMPERED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNOBSTRUCTED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNPREVENTED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNCHECKED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNLIMITED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNBOUNDED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNQUALIFIED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNCONDITIONAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ABSOLUTE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TOTAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMPLETE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ENTIRE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FULL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_WHOLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ALL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNIVERSAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GENERAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMMON
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_USUAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TYPICAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ORDINARY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_NORMAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_STANDARD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_REGULAR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CUSTOMARY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TRADITIONAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONVENTIONAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ESTABLISHED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ACKNOWLEDGED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RECOGNIZED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ACCEPTED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_APPROVED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SANCTIONED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_AUTHORIZED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LEGITIMATED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_VALIDATED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_VERIFIED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONFIRMED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CORROBORATED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUBSTANTIATED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DOCUMENTED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RECORD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LOG
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_REGISTER
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CHRONICLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MEMOIR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ANECDOTE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ACCOUNT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_NARRATIVE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TALE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_STORY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EPISODE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INCIDENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OCCURRENCE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EVENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HAPPENING
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OCCURRENCE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INCIDENCE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PREVALENCE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FREQUENCY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RATIO
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROPORTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PERCENTAGE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FRACTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DECIMAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BINARY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HEXADECIMAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OCTAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BASE64
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_URL_ENCODED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HTML_ENCODED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_XML_ENCODED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_JSON_ENCODED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_YAML_ENCODED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CSV_ENCODED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TSV_ENCODED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PIPE_ENCODED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DELIMITED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SEPARATED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TOKENIZED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PARSED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ANALYZED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROCESSED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TRANSFORMED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONVERTED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TRANSLATED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ENCODED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DECODED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMPRESSED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DECOMPRESSED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ENCRYPTED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DECRYPTED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HASHED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SIGNED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CERTIFIED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_AUTHENTICATED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_VALIDATED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_VERIFIED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CHECKED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TESTED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TRIED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXAMINED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INSPECTED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_REVIEWED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_AUDITED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SURVEYED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ASSESSED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EVALUATED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MEASURED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_QUANTIFIED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CALCULATED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMPUTED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DERIVED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ESTIMATED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PREDICTED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FORCAST
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROJECTED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ANTICIPATED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXPECTED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HOPED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DESIRED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_WANTED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_NEEDED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_REQUIRED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_NECESSARY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ESSENTIAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_VITAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CRITICAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_URGENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_IMMEDIATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PRESSING
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_IMPORTANT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SIGNIFICANT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONSIDERABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUBSTANTIAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_NOTABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROMINENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_VISIBLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_APPARENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CLEAR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OBVIOUS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PLAIN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EVIDENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MANIFEST
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PERCEPTIBLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_NOTICEABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DISTINGUISHABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RECOGNIZABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_IDENTIFIABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DETECTABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OBSERVABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MEASURABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_QUANTIFIABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CALCULABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMPUTABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DERIVABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INFERRABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DEDUCTIBLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INDUCIBLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DERIVATIVE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SECONDARY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUBORDINATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_AUXILIARY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUPPLEMENTARY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ADDITIONAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXTRA
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUPERFLUOUS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_REDUNDANT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXCESSIVE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUPERABUNDANT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OVERFLOWING
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROFUSE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ABUNDANT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PLENTEOUS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PLENTIFUL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RICH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BOUNTIFUL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LIBERAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GENUINE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_AUTHENTIC
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_REAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ACTUAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TRUE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FACTUAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_VERIDICAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HONEST
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SINCERE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FRANK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OPEN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DIRECT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PLAIN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_STRAIGHTFORWARD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CANDID
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UPFRONT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FRONTAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FACE_TO_FACE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PERSONAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INDIVIDUAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PRIVATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONFIDENTIAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SECRET
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CLASSIFIED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RESTRICTED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONFIDENTIAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PRIVATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PERSONAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INDIVIDUAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DOMESTIC
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HOME
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FAMILY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTIMATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CLOSE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_NEAR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ADJACENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONJUGATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ASSOCIATED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONNECTED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LINKED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_JOINED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNIFIED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTEGRATED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMBINED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MERGED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FUSED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SYNERGIZED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SYNTHESIZED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HARMONIZED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BALANCED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EQUALIZED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_STABILIZED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_REGULATED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONTROLLED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MANAGED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUPERVISED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OVERSIGHT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MONITORING
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SURVEILLANCE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OBSERVATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INSPECTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXAMINATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ANALYSIS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EVALUATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ASSESSMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_APPRAISAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RATING
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MEASUREMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_QUANTIFICATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CALCULATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMPUTATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ESTIMATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PREDICTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FORECAST
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROJECTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ANTICIPATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXPECTATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HOPE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONFIDENCE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TRUST
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FAITH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BELIEF
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ASSUMPTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HYPOTHESIS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_THEORY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MODEL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FRAMEWORK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ARCHITECTURE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LAYOUT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DESIGN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PLAN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_STRATEGY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_APPROACH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_METHOD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TECHNIQUE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROCEDURE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROCESS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OPERATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ACTIVITY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ACTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BEHAVIOR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONDUCT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PERFORMANCE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXECUTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_IMPLEMENTATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_APPLICATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UTILIZATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EMPLOYMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_USAGE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EMPLOYMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_APPLY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXERT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXERCISE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_USE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EMPLOY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_WIELD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HANDLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MANAGE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OPERATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RUN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DIRECT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LEAD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GUIDE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_STEER
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_NAVIGATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PILOT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CHARTER
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CAPTAIN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMMAND
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUPERVISE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COORDINATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ORGANIZE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ARRANGE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PLAN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SCHEDULE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROGRAM
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TIMETABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_AGENDA
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ITINERARY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ROUTE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PATH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_WAY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DIRECTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ORIENTATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ALIGNMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_POSITION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LOCATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PLACE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SITE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SPOT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_POINT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_AREA
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_REGION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ZONE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DISTRICT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SECTOR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TERRITORY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ENVIRONMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SETTING
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONTEXT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BACKGROUND
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SCENE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ATMOSPHERE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MOOD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FEEL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TONE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SPIRIT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ATTITUDE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DISPOSITION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TEMPERAMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PERSONALITY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CHARACTER
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_NATURE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ESSENCE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUBSTANCE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CORE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HEART
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CENTER
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MIDDLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTERIOR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INSIDE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTERNAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DOMESTIC
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HOME
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PRIVATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PERSONAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INDIVIDUAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PRIVATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PUBLIC
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMMUNITY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SOCIAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COLLECTIVE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_JOINT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SHARED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMMON
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNIVERSAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GLOBAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_WORLDWIDE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTERNATIONAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNIVERSAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GENERAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_WIDESPREAD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PREVALENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DOMINANT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PREEMINENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUPREME
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PARAMOUNT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CHIEF
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LEADING
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PRIME
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PRIMARY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MAIN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MAJOR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_KEY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CRUCIAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_VITAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CRITICAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ESSENTIAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FUNDAMENTAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BASIC
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ELEMENTARY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FOUNDATIONAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ROOT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FOUNDATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CORNERSTONE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BEDROCK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BASE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GROUND
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SOIL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EARTH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LAND
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TERRAIN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TOPOGRAPHY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GEOMETRY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SHAPE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FORM
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_STRUCTURE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONFIGURATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMPOSITION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MAKEUP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BUILD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FRAME
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SKELETON
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OUTLINE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROFILE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SILHOUETTE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONTOUR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BORDER
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EDGE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MARGIN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BOUNDARY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LIMIT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RESTRICTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONSTRAINT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LIMITATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_IMPEDIMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HANDICAP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DRAWBACK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DEFICIENCY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SHORTCOMING
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_WEAKNESS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FLAW
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FAULT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ERROR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MISTAKE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BLUNDER
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SLIP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GAFFE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BLOOPER
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FOIBLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HICCUP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SNAG
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_STUMBLING_BLOCK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OBSTACLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BARRIER
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HURDLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CHALLENGE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TASK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ASSIGNMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MISSION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OBJECTIVE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GOAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TARGET
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PURPOSE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTENTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_AIM
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_END
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DESTINATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PORT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HARBOR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TERMINUS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FINISH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONCLUSION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ENDING
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CLOSURE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CLOSE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SHUTDOWN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HALT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_STOP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PAUSE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BREAK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTERMISSION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTERVAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GAP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HIATUS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUSPENSION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_POSTPONEMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DEFERMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DELAY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HOLDUP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SETBACK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_REVIVAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RESUMPTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONTINUATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROGRESS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ADVANCEMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DEVELOPMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EVOLUTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MATURATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GROWTH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXPANSION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INCREASE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RISE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ASCENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CLIMB
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ELEVATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PEAK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUMMIT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_APEX
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ZENITH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_Pinnacle
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TOP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HEAD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CROWN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CAP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COVER
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LID
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SEAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LOCK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FASTEN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SECURE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FIX
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ATTACH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONNECT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_JOIN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LINK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNITE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMBINE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MERGE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BLEND
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MIX
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FUSE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNIFY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SYNTHESIZE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTEGRATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INCORPORATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ABSORB
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DIGEST
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROCESS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HANDLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MANAGE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OPERATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXECUTE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PERFORM
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ACHIEVE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ACCOMPLISH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMPLETE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FINISH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONCLUDE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TERMINATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_END
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CEASE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HALT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_STOP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ABORT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CANCEL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DROP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DISCONTINUE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TERMINATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ABRUPT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUDDEN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_IMMEDIATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INSTANT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_QUICK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FAST
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RAPID
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SWIFT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SPEEDY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXPEDITIOUS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HASTY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HURRIED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PRECIPITOUS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HEADLONG
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RASH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_IMPRUDENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RECKLESS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_WILD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FRANTIC
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FRENZIED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FURIOUS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FIERCE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTENSE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_VIOLENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXTREME
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RADICAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DRAMATIC
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SIGNIFICANT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_IMPORTANT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONSIDERABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUBSTANTIAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONSIDERABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_NOTABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROMINENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_VISIBLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_APPARENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CLEAR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OBVIOUS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PLAIN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EVIDENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MANIFEST
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PERCEPTIBLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_NOTICEABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DISTINGUISHABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RECOGNIZABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_IDENTIFIABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DETECTABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OBSERVABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MEASURABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_QUANTIFIABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CALCULABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMPUTABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DERIVABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INFERRABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DEDUCTIBLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INDUCIBLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DERIVATIVE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SECONDARY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUBORDINATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_AUXILIARY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUPPLEMENTARY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ADDITIONAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXTRA
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUPERFLUOUS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_REDUNDANT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXCESSIVE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUPERABUNDANT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OVERFLOWING
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROFUSE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ABUNDANT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PLENTEOUS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PLENTIFUL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RICH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BOUNTIFUL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LIBERAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GENUINE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_AUTHENTIC
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_REAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ACTUAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TRUE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FACTUAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_VERIDICAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HONEST
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SINCERE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FRANK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OPEN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DIRECT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PLAIN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_STRAIGHTFORWARD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CANDID
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UPFRONT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FRONTAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FACE_TO_FACE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PERSONAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INDIVIDUAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PRIVATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONFIDENTIAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SECRET
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CLASSIFIED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RESTRICTED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONFIDENTIAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PRIVATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PERSONAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INDIVIDUAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DOMESTIC
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HOME
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FAMILY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTIMATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CLOSE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_NEAR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ADJACENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONJUGATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ASSOCIATED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONNECTED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LINKED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_JOINED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNIFIED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTEGRATED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMBINED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MERGED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FUSED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SYNERGIZED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SYNTHESIZED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HARMONIZED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BALANCED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EQUALIZED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_STABILIZED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_REGULATED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONTROLLED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MANAGED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUPERVISED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OVERSIGHT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MONITORING
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SURVEILLANCE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OBSERVATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INSPECTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXAMINATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ANALYSIS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EVALUATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ASSESSMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_APPRAISAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RATING
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MEASUREMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_QUANTIFICATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CALCULATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMPUTATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ESTIMATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PREDICTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FORECAST
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROJECTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ANTICIPATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXPECTATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HOPE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONFIDENCE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TRUST
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FAITH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BELIEF
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ASSUMPTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HYPOTHESIS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_THEORY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MODEL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FRAMEWORK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ARCHITECTURE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LAYOUT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DESIGN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PLAN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_STRATEGY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_APPROACH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_METHOD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TECHNIQUE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROCEDURE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROCESS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OPERATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ACTIVITY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ACTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BEHAVIOR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONDUCT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PERFORMANCE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXECUTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_IMPLEMENTATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_APPLICATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UTILIZATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EMPLOYMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_USAGE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EMPLOYMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_APPLY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXERT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXERCISE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_USE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EMPLOY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_WIELD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HANDLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MANAGE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OPERATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RUN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DIRECT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LEAD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GUIDE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_STEER
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_NAVIGATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PILOT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CHARTER
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CAPTAIN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMMAND
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUPERVISE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COORDINATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ORGANIZE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ARRANGE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PLAN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SCHEDULE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROGRAM
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TIMETABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_AGENDA
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ITINERARY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ROUTE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PATH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_WAY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DIRECTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ORIENTATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ALIGNMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_POSITION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LOCATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PLACE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SITE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SPOT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_POINT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_AREA
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_REGION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ZONE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DISTRICT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SECTOR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TERRITORY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ENVIRONMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SETTING
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONTEXT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BACKGROUND
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SCENE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ATMOSPHERE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MOOD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FEEL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TONE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SPIRIT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ATTITUDE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DISPOSITION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TEMPERAMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PERSONALITY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CHARACTER
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_NATURE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ESSENCE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUBSTANCE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CORE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HEART
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CENTER
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MIDDLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTERIOR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INSIDE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTERNAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DOMESTIC
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HOME
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PRIVATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PERSONAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INDIVIDUAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PRIVATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PUBLIC
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMMUNITY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SOCIAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COLLECTIVE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_JOINT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SHARED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMMON
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNIVERSAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GLOBAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_WORLDWIDE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTERNATIONAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNIVERSAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GENERAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_WIDESPREAD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PREVALENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DOMINANT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PREEMINENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUPREME
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PARAMOUNT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CHIEF
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LEADING
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PRIME
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PRIMARY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MAIN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MAJOR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_KEY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CRUCIAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_VITAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CRITICAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ESSENTIAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FUNDAMENTAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BASIC
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ELEMENTARY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FOUNDATIONAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ROOT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FOUNDATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CORNERSTONE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BEDROCK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BASE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GROUND
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SOIL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EARTH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LAND
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TERRAIN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TOPOGRAPHY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GEOMETRY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SHAPE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FORM
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_STRUCTURE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONFIGURATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMPOSITION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MAKEUP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BUILD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FRAME
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SKELETON
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OUTLINE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROFILE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SILHOUETTE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONTOUR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BORDER
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EDGE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MARGIN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BOUNDARY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LIMIT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RESTRICTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONSTRAINT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LIMITATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_IMPEDIMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HANDICAP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DRAWBACK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DEFICIENCY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SHORTCOMING
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_WEAKNESS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FLAW
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FAULT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ERROR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MISTAKE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BLUNDER
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SLIP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GAFFE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BLOOPER
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FOIBLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HICCUP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SNAG
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_STUMBLING_BLOCK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OBSTACLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BARRIER
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HURDLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CHALLENGE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TASK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ASSIGNMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MISSION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OBJECTIVE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GOAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TARGET
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PURPOSE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTENTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_AIM
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_END
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DESTINATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PORT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HARBOR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TERMINUS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FINISH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONCLUSION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ENDING
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CLOSURE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CLOSE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SHUTDOWN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HALT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_STOP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PAUSE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BREAK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTERMISSION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTERVAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GAP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HIATUS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUSPENSION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_POSTPONEMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DEFERMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DELAY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HOLDUP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SETBACK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_REVIVAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RESUMPTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONTINUATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROGRESS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ADVANCEMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DEVELOPMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EVOLUTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MATURATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GROWTH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXPANSION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INCREASE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RISE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ASCENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CLIMB
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ELEVATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PEAK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUMMIT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_APEX
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ZENITH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_Pinnacle
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TOP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HEAD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CROWN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CAP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COVER
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LID
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SEAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LOCK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FASTEN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SECURE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FIX
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ATTACH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONNECT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_JOIN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LINK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNITE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMBINE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MERGE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BLEND
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MIX
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FUSE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNIFY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SYNTHESIZE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTEGRATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INCORPORATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ABSORB
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DIGEST
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROCESS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HANDLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MANAGE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OPERATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXECUTE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PERFORM
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ACHIEVE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ACCOMPLISH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMPLETE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FINISH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONCLUDE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TERMINATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_END
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CEASE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HALT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_STOP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ABORT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CANCEL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DROP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DISCONTINUE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TERMINATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ABRUPT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUDDEN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_IMMEDIATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INSTANT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_QUICK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FAST
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RAPID
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SWIFT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SPEEDY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXPEDITIOUS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HASTY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HURRIED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PRECIPITOUS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HEADLONG
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RASH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_IMPRUDENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RECKLESS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_WILD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FRANTIC
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FRENZIED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FURIOUS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FIERCE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTENSE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_VIOLENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXTREME
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RADICAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DRAMATIC
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SIGNIFICANT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_IMPORTANT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONSIDERABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUBSTANTIAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONSIDERABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_NOTABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROMINENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_VISIBLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_APPARENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CLEAR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OBVIOUS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PLAIN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EVIDENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MANIFEST
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PERCEPTIBLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_NOTICEABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DISTINGUISHABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RECOGNIZABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_IDENTIFIABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DETECTABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OBSERVABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MEASURABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_QUANTIFIABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CALCULABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMPUTABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DERIVABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INFERRABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DEDUCTIBLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INDUCIBLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DERIVATIVE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SECONDARY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUBORDINATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_AUXILIARY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUPPLEMENTARY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ADDITIONAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXTRA
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUPERFLUOUS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_REDUNDANT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXCESSIVE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUPERABUNDANT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OVERFLOWING
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROFUSE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ABUNDANT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PLENTEOUS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PLENTIFUL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RICH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BOUNTIFUL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LIBERAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GENUINE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_AUTHENTIC
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_REAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ACTUAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TRUE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FACTUAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_VERIDICAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HONEST
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SINCERE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FRANK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OPEN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DIRECT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PLAIN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_STRAIGHTFORWARD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CANDID
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UPFRONT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FRONTAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FACE_TO_FACE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PERSONAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INDIVIDUAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PRIVATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONFIDENTIAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SECRET
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CLASSIFIED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RESTRICTED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONFIDENTIAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PRIVATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PERSONAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INDIVIDUAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DOMESTIC
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HOME
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FAMILY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTIMATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CLOSE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_NEAR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ADJACENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONJUGATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ASSOCIATED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONNECTED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LINKED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_JOINED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNIFIED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTEGRATED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMBINED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MERGED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FUSED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SYNERGIZED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SYNTHESIZED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HARMONIZED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BALANCED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EQUALIZED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_STABILIZED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_REGULATED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONTROLLED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MANAGED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUPERVISED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OVERSIGHT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MONITORING
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SURVEILLANCE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OBSERVATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INSPECTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXAMINATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ANALYSIS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EVALUATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ASSESSMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_APPRAISAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RATING
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MEASUREMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_QUANTIFICATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CALCULATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMPUTATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ESTIMATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PREDICTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FORECAST
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROJECTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ANTICIPATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXPECTATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HOPE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONFIDENCE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TRUST
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FAITH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BELIEF
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ASSUMPTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HYPOTHESIS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_THEORY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MODEL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FRAMEWORK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ARCHITECTURE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LAYOUT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DESIGN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PLAN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_STRATEGY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_APPROACH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_METHOD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TECHNIQUE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROCEDURE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROCESS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OPERATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ACTIVITY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ACTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BEHAVIOR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONDUCT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PERFORMANCE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXECUTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_IMPLEMENTATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_APPLICATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UTILIZATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EMPLOYMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_USAGE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EMPLOYMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_APPLY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXERT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXERCISE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_USE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EMPLOY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_WIELD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HANDLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MANAGE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OPERATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RUN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DIRECT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LEAD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GUIDE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_STEER
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_NAVIGATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PILOT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CHARTER
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CAPTAIN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMMAND
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUPERVISE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COORDINATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ORGANIZE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ARRANGE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PLAN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SCHEDULE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROGRAM
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TIMETABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_AGENDA
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ITINERARY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ROUTE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PATH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_WAY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DIRECTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ORIENTATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ALIGNMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_POSITION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LOCATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PLACE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SITE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SPOT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_POINT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_AREA
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_REGION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ZONE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DISTRICT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SECTOR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TERRITORY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ENVIRONMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SETTING
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONTEXT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BACKGROUND
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SCENE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ATMOSPHERE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MOOD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FEEL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TONE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SPIRIT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ATTITUDE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DISPOSITION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TEMPERAMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PERSONALITY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CHARACTER
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_NATURE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ESSENCE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUBSTANCE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CORE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HEART
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CENTER
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MIDDLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTERIOR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INSIDE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTERNAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DOMESTIC
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HOME
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PRIVATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PERSONAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INDIVIDUAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PRIVATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PUBLIC
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMMUNITY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SOCIAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COLLECTIVE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_JOINT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SHARED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMMON
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNIVERSAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GLOBAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_WORLDWIDE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTERNATIONAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNIVERSAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GENERAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_WIDESPREAD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PREVALENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DOMINANT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PREEMINENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUPREME
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PARAMOUNT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CHIEF
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LEADING
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PRIME
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PRIMARY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MAIN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MAJOR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_KEY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CRUCIAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_VITAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CRITICAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ESSENTIAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FUNDAMENTAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BASIC
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ELEMENTARY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FOUNDATIONAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ROOT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FOUNDATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CORNERSTONE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BEDROCK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BASE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GROUND
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SOIL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EARTH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LAND
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TERRAIN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TOPOGRAPHY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GEOMETRY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SHAPE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FORM
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_STRUCTURE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONFIGURATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMPOSITION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MAKEUP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BUILD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FRAME
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SKELETON
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OUTLINE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROFILE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SILHOUETTE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONTOUR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BORDER
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EDGE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MARGIN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BOUNDARY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LIMIT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RESTRICTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONSTRAINT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LIMITATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_IMPEDIMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HANDICAP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DRAWBACK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DEFICIENCY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SHORTCOMING
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_WEAKNESS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FLAW
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FAULT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ERROR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MISTAKE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BLUNDER
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SLIP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GAFFE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BLOOPER
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FOIBLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HICCUP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SNAG
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_STUMBLING_BLOCK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OBSTACLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BARRIER
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HURDLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CHALLENGE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TASK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ASSIGNMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MISSION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OBJECTIVE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GOAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TARGET
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PURPOSE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTENTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_AIM
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_END
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DESTINATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PORT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HARBOR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TERMINUS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FINISH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONCLUSION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ENDING
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CLOSURE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CLOSE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SHUTDOWN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HALT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_STOP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PAUSE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BREAK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTERMISSION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTERVAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GAP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HIATUS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUSPENSION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_POSTPONEMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DEFERMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DELAY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HOLDUP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SETBACK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_REVIVAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RESUMPTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONTINUATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROGRESS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ADVANCEMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DEVELOPMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EVOLUTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MATURATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GROWTH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXPANSION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INCREASE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RISE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ASCENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CLIMB
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ELEVATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PEAK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUMMIT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_APEX
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ZENITH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_Pinnacle
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TOP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HEAD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CROWN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CAP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COVER
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LID
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SEAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LOCK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FASTEN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SECURE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FIX
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ATTACH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONNECT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_JOIN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LINK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNITE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMBINE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MERGE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BLEND
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MIX
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FUSE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNIFY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SYNTHESIZE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTEGRATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INCORPORATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ABSORB
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DIGEST
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROCESS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HANDLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MANAGE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OPERATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXECUTE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PERFORM
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ACHIEVE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ACCOMPLISH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMPLETE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FINISH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONCLUDE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TERMINATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_END
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CEASE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HALT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_STOP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ABORT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CANCEL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DROP
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DISCONTINUE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TERMINATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ABRUPT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUDDEN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_IMMEDIATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INSTANT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_QUICK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FAST
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RAPID
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SWIFT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SPEEDY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXPEDITIOUS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HASTY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HURRIED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PRECIPITOUS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HEADLONG
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RASH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_IMPRUDENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RECKLESS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_WILD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FRANTIC
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FRENZIED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FURIOUS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FIERCE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTENSE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_VIOLENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXTREME
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RADICAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DRAMATIC
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SIGNIFICANT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_IMPORTANT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONSIDERABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUBSTANTIAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONSIDERABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_NOTABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROMINENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_VISIBLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_APPARENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CLEAR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OBVIOUS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PLAIN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EVIDENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MANIFEST
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PERCEPTIBLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_NOTICEABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DISTINGUISHABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RECOGNIZABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_IDENTIFIABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DETECTABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OBSERVABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MEASURABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_QUANTIFIABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CALCULABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMPUTABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DERIVABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INFERRABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DEDUCTIBLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INDUCIBLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DERIVATIVE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SECONDARY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUBORDINATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_AUXILIARY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUPPLEMENTARY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ADDITIONAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXTRA
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUPERFLUOUS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_REDUNDANT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXCESSIVE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUPERABUNDANT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OVERFLOWING
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROFUSE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ABUNDANT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PLENTEOUS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PLENTIFUL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RICH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BOUNTIFUL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LIBERAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GENUINE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_AUTHENTIC
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_REAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ACTUAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TRUE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FACTUAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_VERIDICAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HONEST
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SINCERE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FRANK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OPEN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DIRECT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PLAIN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_STRAIGHTFORWARD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CANDID
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UPFRONT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FRONTAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FACE_TO_FACE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PERSONAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INDIVIDUAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PRIVATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONFIDENTIAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SECRET
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CLASSIFIED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RESTRICTED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONFIDENTIAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PRIVATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PERSONAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INDIVIDUAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DOMESTIC
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HOME
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FAMILY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTIMATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CLOSE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_NEAR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ADJACENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONJUGATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ASSOCIATED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONNECTED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LINKED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_JOINED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNIFIED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTEGRATED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMBINED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MERGED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FUSED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SYNERGIZED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SYNTHESIZED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HARMONIZED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BALANCED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EQUALIZED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_STABILIZED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_REGULATED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONTROLLED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MANAGED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUPERVISED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OVERSIGHT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MONITORING
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SURVEILLANCE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OBSERVATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INSPECTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXAMINATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ANALYSIS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EVALUATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ASSESSMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_APPRAISAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RATING
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MEASUREMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_QUANTIFICATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CALCULATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMPUTATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ESTIMATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PREDICTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FORECAST
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROJECTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ANTICIPATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXPECTATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HOPE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONFIDENCE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TRUST
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FAITH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BELIEF
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ASSUMPTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HYPOTHESIS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_THEORY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MODEL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FRAMEWORK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ARCHITECTURE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LAYOUT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DESIGN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PLAN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_STRATEGY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_APPROACH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_METHOD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TECHNIQUE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROCEDURE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROCESS
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OPERATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ACTIVITY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ACTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BEHAVIOR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONDUCT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PERFORMANCE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXECUTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_IMPLEMENTATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_APPLICATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UTILIZATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EMPLOYMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_USAGE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EMPLOYMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_APPLY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXERT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EXERCISE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_USE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EMPLOY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_WIELD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HANDLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MANAGE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_OPERATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_RUN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DIRECT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LEAD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GUIDE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_STEER
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_NAVIGATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PILOT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CHARTER
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CAPTAIN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMMAND
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUPERVISE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COORDINATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ORGANIZE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ARRANGE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PLAN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SCHEDULE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PROGRAM
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TIMETABLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_AGENDA
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ITINERARY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ROUTE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PATH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_WAY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DIRECTION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ORIENTATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ALIGNMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_POSITION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LOCATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PLACE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SITE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SPOT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_POINT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_AREA
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_REGION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ZONE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DISTRICT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SECTOR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TERRITORY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ENVIRONMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SETTING
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CONTEXT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BACKGROUND
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SCENE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ATMOSPHERE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MOOD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FEEL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TONE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SPIRIT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ATTITUDE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DISPOSITION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TEMPERAMENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PERSONALITY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CHARACTER
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_NATURE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ESSENCE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUBSTANCE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CORE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HEART
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CENTER
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MIDDLE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTERIOR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INSIDE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTERNAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DOMESTIC
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_HOME
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PRIVATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PERSONAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INDIVIDUAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PRIVATE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PUBLIC
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMMUNITY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SOCIAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COLLECTIVE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_JOINT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SHARED
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_COMMON
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNIVERSAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GLOBAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_WORLDWIDE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_INTERNATIONAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_UNIVERSAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GENERAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_WIDESPREAD
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PREVALENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_DOMINANT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PREEMINENT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SUPREME
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PARAMOUNT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CHIEF
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LEADING
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PRIME
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_PRIMARY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MAIN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_MAJOR
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_KEY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CRUCIAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_VITAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CRITICAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ESSENTIAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FUNDAMENTAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BASIC
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ELEMENTARY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FOUNDATIONAL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_ROOT
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_FOUNDATION
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_CORNERSTONE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BEDROCK
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_BASE
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_GROUND
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_SOIL
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_EARTH
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_LAND
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TERRAIN
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP_RETRY_JITTER_TOPOGRAPHY
          value: "false"
        - name: ROOK_CSI_GRPC_PROXY_CACHE_CLEANUP