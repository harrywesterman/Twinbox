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
```

**Step 4: Write Rook cluster configuration**
```yaml
# twinbox/ansible/roles/storage/files/rook-cluster-external.yaml
---
apiVersion: ceph.rook.io/v1
kind: CephCluster
metadata:
  name: rook-ceph-external
  namespace: rook-ceph
spec:
  external:
    enable: true
  dataDirHostPath: /var/lib/rook
  disruptionManagement:
    managePodBudgets: true
    osdMaintenanceTimeout: 30
    machineDisruptionBudgetNamespace: openshift-machine-api
  healthCheck:
    daemonHealth:
      mon:
        interval: 45s
        timeout: 600s
      osd:
        interval: 60s
      status:
        interval: 60s
```

**Step 5: Write storage role task definition**
```yaml
# twinbox/ansible/roles/storage/tasks/main.yml
---
- name: Create storage manifests directory
  file:
    path: /tmp/storage-manifests
    state: directory
    mode: '0755'
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Copy Rook operator manifest
  copy:
    src: rook-operator-1.13.1.yaml
    dest: /tmp/storage-manifests/rook-operator-1.13.1.yaml
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Apply Rook operator
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl apply -f /tmp/storage-manifests/rook-operator-1.13.1.yaml
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Wait for Rook operator to be ready
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl wait --for=condition=ready pods -l app=rook-ceph-operator -n rook-ceph --timeout=300s
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true
  retries: 30
  delay: 10

- name: Copy Rook cluster manifest
  copy:
    src: rook-cluster-external.yaml
    dest: /tmp/storage-manifests/rook-cluster-external.yaml
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Apply Rook cluster
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl apply -f /tmp/storage-manifests/rook-cluster-external.yaml
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Wait for Ceph cluster to be ready
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl wait --for=condition=ready cephclusters -l app=rook-ceph -n rook-ceph --timeout=600s
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true
  retries: 60
  delay: 10

- name: Create default CephBlockPool
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl apply -f - <<EOF
    apiVersion: ceph.rook.io/v1
    kind: CephBlockPool
    metadata:
      name: replicapool
      namespace: rook-ceph
    spec:
      failureDomain: host
      replicated:
        size: 3
    EOF
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Create default CephFileSystem
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl apply -f - <<EOF
    apiVersion: ceph.rook.io/v1
    kind: CephFilesystem
    metadata:
      name: myfs
      namespace: rook-ceph
    spec:
      metadataPool:
        replicated:
          size: 3
      dataPools:
      - replicated:
          size: 3
        name: datapool
      metadataServer:
        activeCount: 1
        activeStandby: true
    EOF
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Create default CephObjectStore
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl apply -f - <<EOF
    apiVersion: ceph.rook.io/v1
    kind: CephObjectStore
    metadata:
      name: my-store
      namespace: rook-ceph
    spec:
      metadataPool:
        replicated:
          size: 3
      dataPool:
        replicated:
          size: 3
      preservePoolsOnDelete: true
      gateway:
        type: s3
        sslCertificateRef:
        port: 80
        securePort: 443
        instances: 1
    EOF
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Create default StorageClass for RBD
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl apply -f - <<EOF
    apiVersion: storage.k8s.io/v1
    kind: StorageClass
    metadata:
      name: rook-ceph-block
    provisioner: rook-ceph.rbd.csi.ceph.com
    parameters:
      clusterID: rook-ceph
      pool: replicapool
      imageFormat: "2"
      imageFeatures: layering
      csi.storage.k8s.io/provisioner-secret-name: rook-csi-rbd-provisioner
      csi.storage.k8s.io/provisioner-secret-namespace: rook-ceph
      csi.storage.k8s.io/node-stage-secret-name: rook-csi-rbd-node
      csi.storage.k8s.io/node-stage-secret-namespace: rook-ceph
      csi.storage.k8s.io/fstype: ext4
    reclaimPolicy: Delete
    allowVolumeExpansion: true
    mountOptions:
    - discard
    EOF
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true
```

**Step 6: Update main playbook to include storage role**
```yaml
# In twinbox/ansible/playbook.yml - add storage role after addons
- hosts: localhost
  become: yes
  roles:
    - storage  # Add this after addons role
```

**Step 7: Run test to verify it passes**
Run: `./tests/test-rook-storage-deployment.sh`
Expected: All tests should pass

**Step 8: Commit**
Run: `git add twinbox/ansible/roles/storage/ tests/test-rook-storage-deployment.sh twinbox/ansible/playbook.yml && git commit -m "Add Rook/Ceph storage implementation"`

### Task 2: Traefik Ingress Controller Implementation

**Files:**
- Create: `twinbox/ansible/roles/traefik/tasks/main.yml`
- Create: `twinbox/ansible/roles/traefik/files/traefik-helm-values.yaml`
- Create: `tests/test-traefik-deployment.sh`
- Modify: `twinbox/ansible/playbook.yml`

**Step 1: Write the failing test for Traefik deployment**
```bash
#!/bin/bash
# tests/test-traefik-deployment.sh

set -e

echo "Testing Traefik ingress controller deployment..."

# Check if traefik namespace exists
NAMESPACE_EXISTS=$(kubectl get namespace traefik --output=name 2>/dev/null || echo "not found")

if [[ "$NAMESPACE_EXISTS" == "not found" ]]; then
    echo "FAIL: traefik namespace does not exist"
    exit 1
else
    echo "PASS: traefik namespace exists"
fi

# Check if traefik pods are running
TRADEFIK_PODS=$(kubectl get pods -n traefik -l app.kubernetes.io/name=traefik --field-selector=status.phase=Running --no-headers | wc -l)

if [[ $TRADEFIK_PODS -eq 0 ]]; then
    echo "FAIL: No running traefik pods found"
    exit 1
else
    echo "PASS: Found $TRADEFIK_PODS running traefik pods"
fi

# Check if traefik service exists
SERVICE_EXISTS=$(kubectl get service traefik -n traefik --output=name 2>/dev/null || echo "not found")

if [[ "$SERVICE_EXISTS" == "not found" ]]; then
    echo "FAIL: traefik service does not exist"
    exit 1
else
    echo "PASS: traefik service exists"
fi

# Check if traefik ingressroute exists
INGRESSROUTE_EXISTS=$(kubectl get ingressroute traefik-dashboard -n traefik --output=name 2>/dev/null || echo "not found")

if [[ "$INGRESSROUTE_EXISTS" == "not found" ]]; then
    echo "FAIL: traefik-dashboard ingressroute does not exist"
    exit 1
else
    echo "PASS: traefik-dashboard ingressroute exists"
fi

echo "All Traefik ingress controller tests passed!"
```

**Step 2: Run test to verify it fails**
Run: `chmod +x tests/test-traefik-deployment.sh && ./tests/test-traefik-deployment.sh`
Expected: Tests should fail because Traefik is not yet deployed

**Step 3: Write Traefik Helm values**
```yaml
# twinbox/ansible/roles/traefik/files/traefik-helm-values.yaml
---
# Default values for Traefik
image:
  name: traefik
  tag: "v2.10.4"
  pullPolicy: IfNotPresent

service:
  enabled: true
  type: LoadBalancer
  annotations: {}
  labels: {}
  spec: {}

ingressRoute:
  dashboard:
    enabled: true
    annotations: {}
    labels:
      expose: "true"

ports:
  web:
    redirectTo:
      port: websecure
  websecure:
    tls:
      enabled: true

providers:
  kubernetesIngress:
    enabled: true
    ingressClass: traefik
    publishedService:
      enabled: true
  kubernetesCRD:
    enabled: true
    ingressClass: traefik

logs:
  general:
    format: json
    level: INFO
  access:
    enabled: true
    format: json

tracing: {}

metrics:
  prometheus:
    enabled: true

deployment:
  enabled: true
  replicas: 1
  annotations: {}
  labels: {}
  podAnnotations: {}
  podLabels: {}
  strategy: {}
  hostNetwork: false
  dnsPolicy: ClusterFirst
  additionalContainers: []
  additionalInitContainers: []

podSecurityPolicy:
  enabled: false

resources: {}
```

**Step 4: Write Traefik role task definition**
```yaml
# twinbox/ansible/roles/traefik/tasks/main.yml
---
- name: Create traefik manifests directory
  file:
    path: /tmp/traefik-manifests
    state: directory
    mode: '0755'
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Check if Helm is installed
  shell: command -v helm
  register: helm_check
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true
  ignore_errors: true

- name: Install Helm if not present
  shell: |
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true
  when: helm_check.rc != 0

- name: Add Traefik Helm repository
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    helm repo add traefik https://helm.traefik.io/traefik
    helm repo update
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Create Traefik namespace
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl create namespace traefik --dry-run=client -o yaml | kubectl apply -f -
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Copy Traefik Helm values
  copy:
    src: traefik-helm-values.yaml
    dest: /tmp/traefik-manifests/traefik-helm-values.yaml
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Install Traefik using Helm
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    helm upgrade --install traefik traefik/traefik \
      --namespace traefik \
      --values /tmp/traefik-manifests/traefik-helm-values.yaml \
      --version 22.0.0
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Wait for Traefik pods to be ready
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl wait --for=condition=ready pods -l app.kubernetes.io/name=traefik -n traefik --timeout=300s
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true
  retries: 30
  delay: 10

- name: Verify Traefik service is accessible
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl get service traefik -n traefik
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true
```

**Step 5: Update main playbook to include traefik role**
```yaml
# In twinbox/ansible/playbook.yml - add traefik role after storage
- hosts: localhost
  become: yes
  roles:
    - traefik  # Add this after storage role
```

**Step 6: Run test to verify it passes**
Run: `./tests/test-traefik-deployment.sh`
Expected: All tests should pass

**Step 7: Commit**
Run: `git add twinbox/ansible/roles/traefik/ tests/test-traefik-deployment.sh twinbox/ansible/playbook.yml && git commit -m "Add Traefik ingress controller implementation"`

### Task 3: ArgoCD GitOps Implementation

**Files:**
- Create: `twinbox/ansible/roles/argocd/tasks/main.yml`
- Create: `twinbox/ansible/roles/argocd/files/argocd-helm-values.yaml`
- Create: `tests/test-argocd-deployment.sh`
- Modify: `twinbox/ansible/playbook.yml`

**Step 1: Write the failing test for ArgoCD deployment**
```bash
#!/bin/bash
# tests/test-argocd-deployment.sh

set -e

echo "Testing ArgoCD deployment..."

# Check if argocd namespace exists
NAMESPACE_EXISTS=$(kubectl get namespace argocd --output=name 2>/dev/null || echo "not found")

if [[ "$NAMESPACE_EXISTS" == "not found" ]]; then
    echo "FAIL: argocd namespace does not exist"
    exit 1
else
    echo "PASS: argocd namespace exists"
fi

# Check if argocd-server pod is running
ARGOCD_SERVER_PODS=$(kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server --field-selector=status.phase=Running --no-headers | wc -l)

if [[ $ARGOCD_SERVER_PODS -eq 0 ]]; then
    echo "FAIL: No running argocd-server pods found"
    exit 1
else
    echo "PASS: Found $ARGOCD_SERVER_PODS running argocd-server pods"
fi

# Check if argocd-repo-server pod is running
ARGOCD_REPO_PODS=$(kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-repo-server --field-selector=status.phase=Running --no-headers | wc -l)

if [[ $ARGOCD_REPO_PODS -eq 0 ]]; then
    echo "FAIL: No running argocd-repo-server pods found"
    exit 1
else
    echo "PASS: Found $ARGOCD_REPO_PODS running argocd-repo-server pods"
fi

# Check if argocd-application-controller pod is running
ARGOCD_CONTROLLER_PODS=$(kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-application-controller --field-selector=status.phase=Running --no-headers | wc -l)

if [[ $ARGOCD_CONTROLLER_PODS -eq 0 ]]; then
    echo "FAIL: No running argocd-application-controller pods found"
    exit 1
else
    echo "PASS: Found $ARGOCD_CONTROLLER_PODS running argocd-application-controller pods"
fi

# Check if argocd service exists
SERVICE_EXISTS=$(kubectl get service argocd-server -n argocd --output=name 2>/dev/null || echo "not found")

if [[ "$SERVICE_EXISTS" == "not found" ]]; then
    echo "FAIL: argocd-server service does not exist"
    exit 1
else
    echo "PASS: argocd-server service exists"
fi

echo "All ArgoCD tests passed!"
```

**Step 2: Run test to verify it fails**
Run: `chmod +x tests/test-argocd-deployment.sh && ./tests/test-argocd-deployment.sh`
Expected: Tests should fail because ArgoCD is not yet deployed

**Step 3: Write ArgoCD Helm values**
```yaml
# twinbox/ansible/roles/argocd/files/argocd-helm-values.yaml
---
# Default values for ArgoCD
global:
  image:
    repository: quay.io/argoproj/argocd
    tag: v2.8.4
    imagePullPolicy: IfNotPresent

configs:
  secret:
    createSecret: true
    # Initial admin password (base64 encoded)
    argocdServerAdminPassword: ""
    # Initial admin password (bcrypt encrypted)
    argocdServerAdminPasswordBcrypt: ""

server:
  name: server
  replicas: 1
  
  service:
    type: LoadBalancer
    annotations: {}
    labels: {}
  
  ingress:
    enabled: false
    
  route:
    enabled: false

repoServer:
  name: repo-server
  replicas: 1
  
  service:
    annotations: {}
    labels: {}

applicationSet:
  enabled: true
  replicaCount: 1

controller:
  name: application-controller
  replicas: 1
  
  service:
    annotations: {}
    labels: {}

redis:
  enabled: true
  replica:
    replicaCount: 1

dex:
  enabled: true
  replicaCount: 1

crds:
  keep: false

prometheus:
  enabled: false

grafana:
  enabled: false

openshift:
  enabled: false

extraObjects: []
```

**Step 4: Write ArgoCD role task definition**
```yaml
# twinbox/ansible/roles/argocd/tasks/main.yml
---
- name: Create argocd manifests directory
  file:
    path: /tmp/argocd-manifests
    state: directory
    mode: '0755'
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Add ArgoCD Helm repository
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    helm repo add argo https://argoproj.github.io/argo-helm
    helm repo update
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Create ArgoCD namespace
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Copy ArgoCD Helm values
  copy:
    src: argocd-helm-values.yaml
    dest: /tmp/argocd-manifests/argocd-helm-values.yaml
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Install ArgoCD using Helm
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    helm upgrade --install argo-cd argo/argo-cd \
      --namespace argocd \
      --values /tmp/argocd-manifests/argocd-helm-values.yaml \
      --version 5.45.0
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Wait for ArgoCD server pod to be ready
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl wait --for=condition=ready pods -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true
  retries: 30
  delay: 10

- name: Wait for ArgoCD repo server pod to be ready
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl wait --for=condition=ready pods -l app.kubernetes.io/name=argocd-repo-server -n argocd --timeout=300s
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true
  retries: 30
  delay: 10

- name: Wait for ArgoCD application controller pod to be ready
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl wait --for=condition=ready pods -l app.kubernetes.io/name=argocd-application-controller -n argocd --timeout=300s
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true
  retries: 30
  delay: 10

- name: Get initial admin password
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true
  register: initial_password
  changed_when: false

- name: Display initial admin password
  debug:
    msg: "ArgoCD initial admin password: {{ initial_password.stdout }}"
  run_once: true

- name: Patch ArgoCD server service to LoadBalancer
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl patch service argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}'
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true
```

**Step 5: Update main playbook to include argocd role**
```yaml
# In twinbox/ansible/playbook.yml - add argocd role after traefik
- hosts: localhost
  become: yes
  roles:
    - argocd  # Add this after traefik role
```

**Step 6: Run test to verify it passes**
Run: `./tests/test-argocd-deployment.sh`
Expected: All tests should pass

**Step 7: Commit**
Run: `git add twinbox/ansible/roles/argocd/ tests/test-argocd-deployment.sh twinbox/ansible/playbook.yml && git commit -m "Add ArgoCD GitOps implementation"`

### Task 4: Cloudflare Tunnel Implementation

**Files:**
- Create: `twinbox/ansible/roles/cloudflared/tasks/main.yml`
- Create: `twinbox/ansible/roles/cloudflared/files/cloudflared-config.yaml`
- Create: `tests/test-cloudflared-deployment.sh`
- Modify: `twinbox/ansible/playbook.yml`

**Step 1: Write the failing test for Cloudflare tunnel deployment**
```bash
#!/bin/bash
# tests/test-cloudflared-deployment.sh

set -e

echo "Testing Cloudflare tunnel deployment..."

# Check if cloudflared namespace exists
NAMESPACE_EXISTS=$(kubectl get namespace cloudflared --output=name 2>/dev/null || echo "not found")

if [[ "$NAMESPACE_EXISTS" == "not found" ]]; then
    echo "FAIL: cloudflared namespace does not exist"
    exit 1
else
    echo "PASS: cloudflared namespace exists"
fi

# Check if cloudflared daemonset is running
CLOUDFLARED_PODS=$(kubectl get pods -n cloudflared -l app=cloudflared --field-selector=status.phase=Running --no-headers | wc -l)

if [[ $CLOUDFLARED_PODS -eq 0 ]]; then
    echo "FAIL: No running cloudflared pods found"
    exit 1
else
    echo "PASS: Found $CLOUDFLARED_PODS running cloudflared pods"
fi

# Check if cloudflared service exists
SERVICE_EXISTS=$(kubectl get service cloudflared -n cloudflared --output=name 2>/dev/null || echo "not found")

if [[ "$SERVICE_EXISTS" == "not found" ]]; then
    echo "FAIL: cloudflared service does not exist"
    exit 1
else
    echo "PASS: cloudflared service exists"
fi

# Check if cloudflared secret exists (for tunnel configuration)
SECRET_EXISTS=$(kubectl get secret cloudflared-config -n cloudflared --output=name 2>/dev/null || echo "not found")

if [[ "$SECRET_EXISTS" == "not found" ]]; then
    echo "FAIL: cloudflared-config secret does not exist"
    exit 1
else
    echo "PASS: cloudflared-config secret exists"
fi

echo "All Cloudflare tunnel tests passed!"
```

**Step 2: Run test to verify it fails**
Run: `chmod +x tests/test-cloudflared-deployment.sh && ./tests/test-cloudflared-deployment.sh`
Expected: Tests should fail because Cloudflared is not yet deployed

**Step 3: Write Cloudflared configuration**
```yaml
# twinbox/ansible/roles/cloudflared/files/cloudflared-config.yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: cloudflared-config
  namespace: cloudflared
data:
  config.yaml: |
    tunnel: YOUR_TUNNEL_ID
    credentials-file: /etc/cloudflared/creds/credentials.json
    
    ingress:
    - hostname: yourdomain.example.com
      service: http://traefik.traefik.svc.cluster.local:80
    - hostname: "*.yourdomain.example.com"
      service: http://traefik.traefik.svc.cluster.local:80
    - service: http_status:404
```

**Step 4: Write Cloudflared role task definition**
```yaml
# twinbox/ansible/roles/cloudflared/tasks/main.yml
---
- name: Create cloudflared manifests directory
  file:
    path: /tmp/cloudflared-manifests
    state: directory
    mode: '0755'
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Create cloudflared namespace
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl create namespace cloudflared --dry-run=client -o yaml | kubectl apply -f -
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Copy Cloudflared config
  copy:
    src: cloudflared-config.yaml
    dest: /tmp/cloudflared-manifests/cloudflared-config.yaml
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Create Cloudflared configmap
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl apply -f /tmp/cloudflared-manifests/cloudflared-config.yaml
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Create placeholder for Cloudflared credentials
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl create secret generic cloudflared-config \
      --from-literal=credentials.json='{"TunnelID":"YOUR_TUNNEL_ID","AccountTag":"YOUR_ACCOUNT_TAG","TunnelSecret":"YOUR_TUNNEL_SECRET"}' \
      --namespace cloudflared \
      --dry-run=client -o yaml | kubectl apply -f -
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Deploy Cloudflared as DaemonSet
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl apply -f - <<EOF
    apiVersion: apps/v1
    kind: DaemonSet
    metadata:
      name: cloudflared
      namespace: cloudflared
      labels:
        app: cloudflared
    spec:
      selector:
        matchLabels:
          app: cloudflared
      template:
        metadata:
          labels:
            app: cloudflared
        spec:
          serviceAccountName: cloudflared
          containers:
          - name: cloudflared
            image: cloudflare/cloudflared:2023.10.0
            args:
            - tunnel
            - --config
            - /etc/cloudflared/config/config.yaml
            - run
            env:
            - name: TUNNEL_TOKEN
              valueFrom:
                secretKeyRef:
                  name: cloudflared-config
                  key: credentials.json
            volumeMounts:
            - name: config
              mountPath: /etc/cloudflared/config
              readOnly: true
            - name: creds
              mountPath: /etc/cloudflared/creds
              readOnly: true
            livenessProbe:
              httpGet:
                path: /ready
                port: 2000
              initialDelaySeconds: 30
              periodSeconds: 30
          volumes:
          - name: config
            configMap:
              name: cloudflared-config
          - name: creds
            secret:
              secretName: cloudflared-config
          tolerations:
          - effect: NoSchedule
            operator: Exists
          - effect: NoExecute
            operator: Exists
    EOF
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Create Cloudflared service account
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl apply -f - <<EOF
    apiVersion: v1
    kind: ServiceAccount
    metadata:
      name: cloudflared
      namespace: cloudflared
    ---
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRole
    metadata:
      name: cloudflared
    rules:
    - apiGroups: [""]
      resources: ["endpoints", "services"]
      verbs: ["list", "get", "watch"]
    ---
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRoleBinding
    metadata:
      name: cloudflared
    roleRef:
      apiGroup: rbac.authorization.k8s.io
      kind: ClusterRole
      name: cloudflared
    subjects:
    - kind: ServiceAccount
      name: cloudflared
      namespace: cloudflared
    EOF
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Create Cloudflared service
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl apply -f - <<EOF
    apiVersion: v1
    kind: Service
    metadata:
      name: cloudflared
      namespace: cloudflared
    spec:
      type: LoadBalancer
      ports:
        - port: 80
          targetPort: 8080
          protocol: TCP
          name: http
      selector:
        app: cloudflared
    EOF
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Wait for Cloudflared pods to be ready
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl wait --for=condition=ready pods -l app=cloudflared -n cloudflared --timeout=300s
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true
  retries: 30
  delay: 10

- name: Display setup instructions for Cloudflare tunnel
  debug:
    msg: |
      Cloudflare tunnel setup instructions:
      1. Login to Cloudflare: cloudflared tunnel login
      2. Create a tunnel: cloudflared tunnel create <tunnel-name>
      3. Get the tunnel credentials: cloudflared tunnel info <tunnel-name>
      4. Update the cloudflared-config secret with actual credentials:
         kubectl create secret generic cloudflared-config \
           --from-literal=credentials.json='{"TunnelID":"...","AccountTag":"...","TunnelSecret":"..."}' \
           --namespace cloudflared --save-config --dry-run=client -o yaml | kubectl apply -f -
      5. Update the configmap with actual tunnel ID and hostname:
         kubectl edit configmap cloudflared-config -n cloudflared
  run_once: true
```

**Step 5: Update main playbook to include cloudflared role**
```yaml
# In twinbox/ansible/playbook.yml - add cloudflared role after argocd
- hosts: localhost
  become: yes
  roles:
    - cloudflared  # Add this after argocd role
```

**Step 6: Run test to verify it passes**
Run: `./tests/test-cloudflared-deployment.sh`
Expected: All tests should pass

**Step 7: Commit**
Run: `git add twinbox/ansible/roles/cloudflared/ tests/test-cloudflared-deployment.sh twinbox/ansible/playbook.yml && git commit -m "Add Cloudflare tunnel implementation"`

### Task 5: Update Documentation

**Files:**
- Modify: `twinbox/docs/getting-started.md`
- Modify: `twinbox/docs/configuration.md`
- Create: `twinbox/docs/storage-guide.md`
- Create: `twinbox/docs/ingress-guide.md`
- Create: `twinbox/docs/gitops-guide.md`
- Create: `twinbox/docs/tunneling-guide.md`

**Step 1: Update getting started documentation**
```markdown
# twinbox/docs/getting-started.md

<!-- Add sections about new features -->
## Storage Management with Rook/Ceph

Twinbox includes Rook/Ceph for distributed storage management. This provides highly available, scalable storage for your applications.

## Ingress Control with Traefik

Traefik is configured as the default ingress controller, providing advanced routing capabilities and automatic certificate management.

## GitOps with ArgoCD

ArgoCD is integrated for GitOps-style deployment management, enabling declarative configuration and automated synchronization.

## Secure Access with Cloudflare Tunnels

Cloudflare tunnels provide secure, encrypted access to your services without exposing public IPs.
```

**Step 2: Update configuration documentation**
```markdown
# twinbox/docs/configuration.md

<!-- Add configuration details for new components -->

## Storage Configuration

Rook/Ceph is deployed with the following defaults:
- Namespace: `rook-ceph`
- Default storage class: `rook-ceph-block`
- Block pool: `replicapool`
- File system: `myfs`

To customize storage, modify the role variables in `twinbox/ansible/roles/storage/`.

## Ingress Configuration

Traefik is deployed with the following defaults:
- Namespace: `traefik`
- Service type: `LoadBalancer`
- Dashboard accessible via ingress

To customize ingress, modify the role variables in `twinbox/ansible/roles/traefik/`.

## GitOps Configuration

ArgoCD is deployed with the following defaults:
- Namespace: `argocd`
- Admin password stored in secret
- ApplicationSet controller enabled

To customize GitOps, modify the role variables in `twinbox/ansible/roles/argocd/`.

## Tunnel Configuration

Cloudflared is deployed as a daemonset with the following defaults:
- Namespace: `cloudflared`
- Requires manual credential setup
- Routes traffic to internal services

To customize tunneling, modify the role variables in `twinbox/ansible/roles/cloudflared/`.
```

**Step 3: Create storage guide**
```markdown
# twinbox/docs/storage-guide.md

# Storage Management with Rook/Ceph

This guide explains how to use and configure Rook/Ceph storage in Twinbox.

## Overview

Rook turns Ceph into a self-managing, self-scaling, and self-healing storage service. It automates the tasks of a storage administrator: deployment, bootstrapping, configuration, scaling, upgrading, and more.

## Default Configuration

By default, Twinbox deploys:
- Ceph cluster in `rook-ceph` namespace
- Block pool named `replicapool`
- File system named `myfs`
- Object store named `my-store`
- StorageClass `rook-ceph-block` for dynamic provisioning

## Creating Persistent Volumes

Applications can use Rook/Ceph storage by referencing the default StorageClass:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mysql-pv-claim
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 20Gi
  storageClassName: rook-ceph-block  # Use the Rook storage class
```

## Managing Pools

To create additional pools, apply CephBlockPool resources:

```bash
kubectl apply -f - <<EOF
apiVersion: ceph.rook.io/v1
kind: CephBlockPool
metadata:
  name: custom-pool
  namespace: rook-ceph
spec:
  failureDomain: host
  replicated:
    size: 3
EOF
```

## Troubleshooting

Check the status of your Ceph cluster:
```bash
kubectl -n rook-ceph get cephcluster
kubectl -n rook-ceph get pods -l app=rook-ceph-operator
kubectl -n rook-ceph describe cephcluster rook-ceph-external
```
```

**Step 4: Create ingress guide**
```markdown
# twinbox/docs/ingress-guide.md

# Ingress Control with Traefik

This guide explains how to use and configure Traefik ingress in Twinbox.

## Overview

Traefik is a modern HTTP reverse proxy and load balancer that makes deploying microservices easy. Twinbox deploys Traefik with Kubernetes integration for automatic service discovery.

## Default Configuration

By default, Twinbox deploys:
- Traefik in `traefik` namespace
- LoadBalancer service for external access
- Dashboard accessible via ingress
- Automatic TLS with Let's Encrypt

## Creating Ingress Resources

Define ingress resources to expose your applications:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: example-ingress
  namespace: default
  annotations:
    kubernetes.io/ingress.class: "traefik"
spec:
  rules:
  - host: example.yourdomain.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: example-service
            port:
              number: 80
```

## Traefik Specific Features

For more advanced routing, you can use Traefik's CRDs:

```yaml
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: example-route
  namespace: default
spec:
  entryPoints:
    - web
  routes:
  - match: Host(`example.yourdomain.com`) && PathPrefix(`/api`)
    kind: Rule
    services:
    - name: api-service
      port: 80
```

## Dashboard Access

Access the Traefik dashboard using port forwarding:
```bash
kubectl port-forward -n traefik svc/traefik 9000:80
```

Then visit http://localhost:9000/dashboard/

## SSL/TLS Configuration

Traefik automatically handles TLS certificates when using proper hostnames. Configure ACME for Let's Encrypt certificates in the Helm values.
```

**Step 5: Create GitOps guide**
```markdown
# twinbox/docs/gitops-guide.md

# GitOps with ArgoCD

This guide explains how to use ArgoCD for GitOps workflows in Twinbox.

## Overview

ArgoCD is a declarative, GitOps continuous delivery tool for Kubernetes. It follows the GitOps model by using Git repositories as the source of truth for defining the desired application state.

## Default Configuration

By default, Twinbox deploys:
- ArgoCD in `argocd` namespace
- All ArgoCD components with high availability
- Initial admin password stored in a secret
- ApplicationSet controller for automated application management

## Getting Started

1. Get the initial admin password:
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

2. Access the ArgoCD UI:
```bash
kubectl port-forward svc/argocd-server -n argocd 8080:80
```

3. Log in with username `admin` and the password from step 1.

## Creating Applications

Register your Git repository and create applications through the UI or CLI:

```bash
argocd repo add https://github.com/your-org/your-repo --insecure
argocd app create my-app \
  --repo https://github.com/your-org/your-repo \
  --path path/to/manifests \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace default
```

## Sync Strategies

ArgoCD supports different sync strategies:
- **Automatic**: Automatically sync when the repo changes
- **Manual**: Manually trigger sync from UI/CLI

## Project Creation

Organize applications into projects for access control and resource restrictions:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: my-project
  namespace: argocd
spec:
  sourceRepos:
  - '*'
  destinations:
  - namespace: '*'
    server: '*'
  clusterResourceWhitelist:
  - group: '*'
    kind: '*'
```

## Troubleshooting

Check ArgoCD component status:
```bash
kubectl get pods -n argocd
kubectl logs -n argocd deployment/argocd-server
kubectl logs -n argocd deployment/argocd-repo-server
kubectl logs -n argocd deployment/argocd-application-controller
```
```

**Step 6: Create tunneling guide**
```markdown
# twinbox/docs/tunneling-guide.md

# Secure Access with Cloudflare Tunnels

This guide explains how to set up and use Cloudflare tunnels for secure access to your services.

## Overview

Cloudflare Tunnels provide secure, encrypted connections between your origin servers and Cloudflare's global network, without exposing public IP addresses. Twinbox deploys cloudflared as a daemonset for high availability.

## Prerequisites

Before setting up Cloudflare tunnels, you need:
- A Cloudflare account
- The `cloudflared` command-line tool installed locally
- Access to your domain in Cloudflare DNS

## Initial Setup

1. Authenticate with Cloudflare:
```bash
cloudflared tunnel login
```

2. Create a tunnel:
```bash
cloudflared tunnel create <tunnel-name>
```

3. Note the tunnel ID and credentials from the command output.

## Configuring Twinbox

1. Update the credentials secret with your actual tunnel credentials:
```bash
kubectl create secret generic cloudflared-config \
  --from-literal=credentials.json='{"TunnelID":"YOUR_TUNNEL_ID","AccountTag":"YOUR_ACCOUNT_TAG","TunnelSecret":"YOUR_TUNNEL_SECRET"}' \
  --namespace cloudflared --save-config --dry-run=client -o yaml | kubectl apply -f -
```

2. Update the configmap with your actual tunnel ID and hostnames:
```bash
kubectl edit configmap cloudflared-config -n cloudflared
```

Update the config to use your actual tunnel ID and domain:
```yaml
data:
  config.yaml: |
    tunnel: ACTUAL_TUNNEL_ID
    credentials-file: /etc/cloudflared/creds/credentials.json
    
    ingress:
    - hostname: yourdomain.example.com
      service: http://traefik.traefik.svc.cluster.local:80
    - hostname: "*.yourdomain.example.com"
      service: http://traefik.traefik.svc.cluster.local:80
    - service: http_status:404
```

3. Restart the daemonset to pick up the new configuration:
```bash
kubectl rollout restart daemonset/cloudflared -n cloudflared
```

4. Create DNS records in Cloudflare to point to your tunnel:
```bash
cloudflared tunnel route dns <tunnel-name> yourdomain.example.com
```

## Routing Traffic

By default, the tunnel configuration routes traffic to the Traefik ingress controller. You can modify the ingress section in the configmap to route to different services:

```yaml
ingress:
- hostname: api.yourdomain.com
  service: http://api-service.namespace.svc.cluster.local:80
- hostname: dashboard.yourdomain.com
  service: http://argocd-server.argocd.svc.cluster.local:80
- service: http_status:404
```

## Multiple Tunnels

For more complex setups, you can deploy multiple cloudflared instances with different configurations by creating additional daemonsets with unique names and configurations.

## Troubleshooting

Check cloudflared daemonset status:
```bash
kubectl get pods -n cloudflared
kubectl logs -l app=cloudflared -n cloudflared
kubectl describe daemonset cloudflared -n cloudflared
```

Verify tunnel connectivity from a pod:
```bash
kubectl exec -it -n cloudflared ds/cloudflared -- cloudflared tunnel info
```

Check the cloudflared configuration:
```bash
kubectl get configmap cloudflared-config -n cloudflared -o yaml
kubectl get secret cloudflared-config -n cloudflared -o yaml
```
```

**Step 7: Update main playbook to include all roles**
```yaml
# twinbox/ansible/playbook.yml
---
- hosts: localhost
  become: yes
  vars:
    # Existing variables...
  roles:
    - prerequisites
    - container_runtime
    - kubeadm_setup
    - cni_install
    - addons
    - storage
    - traefik
    - argocd
    - cloudflared
    - monitoring
    - security
    - user_management
```

**Step 8: Commit all documentation changes**
Run: `git add twinbox/docs/ twinbox/ansible/playbook.yml && git commit -m "Add documentation for new platform features"`

## Summary

This implementation plan provides comprehensive TDD-based tasks for implementing:

1. **Rook/Ceph Storage** - Distributed storage solution with block, file, and object storage
2. **Traefik Ingress Controller** - Modern ingress controller with automatic HTTPS
3. **ArgoCD GitOps** - Declarative continuous delivery platform
4. **Cloudflare Tunnels** - Secure access without exposing public IPs

Each feature follows the TDD approach with:
- Failing tests first
- Implementation that makes tests pass
- Verification steps
- Proper documentation

The plan maintains Twinbox's architecture patterns and integrates seamlessly with existing components.