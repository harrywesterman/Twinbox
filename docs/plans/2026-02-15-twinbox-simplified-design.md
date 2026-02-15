# Twinbox: Simplified Design

**Date**: 2026-02-15
**Status**: Proposed
**Goal**: Enormously simplify Twinbox to achieve "Next, Next, Finish" UX for deploying production-ready Kubernetes clusters on Proxmox

---

## Executive Summary

Twinbox is being redesigned from the ground up with **extreme simplicity** as the primary goal. The entire system consists of:

1. **Phase 1**: A single bash script run on Proxmox console that creates only a Management VM
2. **Phase 2**: A web GUI running on that Management VM that automatically discovers, plans, and deploys a complete Kubernetes cluster with zero user configuration

The user experience: Run one command → Open browser → Review auto-generated plan → Click "Start" → Wait 5-10 minutes → Download kubeconfig.

---

## Design Principles

- **Zero configuration intelligence**: The system auto-detects resources, makes placement decisions, and configures sensible defaults
- **Web-only interface**: Users never SSH or run commands manually after the initial script
- **Container-native**: Management VM runs everything in Docker containers with proper orchestration
- **Production-ready**: Includes MetalLB (load balancer), Traefik (ingress), Calico (CNI), and proper security
- **Multi-cluster support**: Can deploy multiple independent clusters on the same Proxmox environment
- **Recoverable state**: All state in PostgreSQL; deployments can be resumed after failures

---

## Phase 1: Proxmox Bootstrap Script

### User Action
```bash
bash <(curl -s https://raw.githubusercontent.com/your-org/twinbox/main/setup-wizard.sh)
```

### Script Flow

1. **Prompt for inputs**:
   - Cluster name (e.g., "production", "staging")
   - (Optional) Management VM resources: CPU, RAM, disk (with smart defaults)
   - (Optional) Proxmox node to use (default: auto-select)

2. **Create Proxmox infrastructure**:
   - Create user `twinbox@pve` with limited ACL
   - Create resource pool `twinbox-<cluster-name>`
   - Grant permissions: `VM.Create`, `VM.Modify`, `VM.PowerMgmt`, `Pool.List` on that pool
   - Generate API token: `twinbox@pve!twinbox-token-<random>`

3. **Create Management VM**:
   - Use Ubuntu 22.04 Cloud Image
   - VM name: `twinbox-mgmt-<cluster-name>`
   - Allocate resources from user input or defaults (2 CPU, 4GB RAM, 32GB disk)
   - Place on least-loaded Proxmox node
   - Configure cloud-init to:
     - Install Docker, docker-compose
     - Clone/download Twinbox repository
     - Generate random database password
     - Create `/opt/twinbox/.env` with secrets
     - Copy Proxmox credentials to `/opt/twinbox/config/proxmox-creds.yaml`
     - Run `docker-compose up -d`
     - Start systemd service to auto-restart on boot

4. **Obtain Management VM IP**:
   - Wait for VM to boot
   - Query Proxmox API for QGA agent IP or use `arp` scan
   - Display: "✅ Management VM ready! Open browser to: http://<IP>:8080"

### Script Characteristics
- **~200 lines of bash**
- No external dependencies beyond standard Proxmox tools (`qm`, `pvesh`)
- Idempotent: can be re-run to recreate/repair
- Clean error handling and validation

---

## Phase 2: Management VM Web System

### Architecture

```
Management VM (Ubuntu 22.04 Cloud)
├── Docker + docker-compose
├── /opt/twinbox/
│   ├── docker-compose.yml
│   ├── .env (DB_PASSWORD, SECRET_KEY, etc.)
│   ├── web/ (FastAPI application)
│   ├── worker/ (RQ worker)
│   ├── config/
│   │   ├── proxmox-creds.yaml (injected by Phase 1)
│   │   ├── talos/ (generated machine configs)
│   │   ├── kubeconfig (cluster credentials)
│   │   └── logs/
│   └── backup/
└── (Docker volumes: postgres-data, redis-data)

Container Stack:
├── PostgreSQL 16 (persistent cluster state)
├── Redis 7 (message broker for RQ)
├── FastAPI Web Service (port 8080)
└── RQ Worker (executes deployment tasks)
```

### Container Images

All services built from local Dockerfiles during first boot:

**web/Dockerfile**:
```dockerfile
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY . .
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
```

**worker/Dockerfile**:
```dockerfile
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY . .
CMD ["rq", "worker", "--url", "redis://redis:6379", "twinbox"]
```

**Mounts**: Worker container needs access to host binaries (`/usr/bin/talosctl`, `/usr/bin/kubectl`, `/usr/bin/qm`) and Docker socket (for Proxmox API calls via SSH alternative). Actually, worker will use Proxmox HTTP API directly, so no QM needed. But does need `talosctl` and `kubectl` binaries installed on host, mounted read-only.

Phase 1 script also installs: `docker.io`, `docker-compose`, `talosctl`, `kubectl`, `jq`, `yq` on the Management VM.

---

## Database Schema (PostgreSQL)

### Tables

**clusters**
```sql
CREATE TABLE clusters (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) UNIQUE NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    status VARCHAR(50) DEFAULT 'pending',
    proxmox_creds_encrypted TEXT,
    network_bridge VARCHAR(100),
    network_cidr CIDR,
    network_gateway INET,
    ip_range_start INET,
    ip_range_end INET
);
```

**vm_plans** (pre-deployment specifications)
```sql
CREATE TABLE vm_plans (
    id SERIAL PRIMARY KEY,
    cluster_id INT REFERENCES clusters(id),
    vm_name VARCHAR(255) NOT NULL,
    role VARCHAR(50) NOT NULL,  -- 'management', 'controlplane', 'worker'
    target_node VARCHAR(255),
    cpu INT NOT NULL,
    ram_mb INT NOT NULL,
    disk_gb INT NOT NULL,
    ip_address INET,
    mac_address VARCHAR(17)
);
```

**deployments** (execution history)
```sql
CREATE TABLE deployments (
    id SERIAL PRIMARY KEY,
    cluster_id INT REFERENCES clusters(id),
    status VARCHAR(50) DEFAULT 'queued',  -- queued, running, succeeded, failed
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    error_message TEXT
);
```

**jobs** (RQ task records)
```sql
CREATE TABLE jobs (
    id SERIAL PRIMARY KEY,
    deployment_id INT REFERENCES deployments(id),
    job_id VARCHAR(255) UNIQUE NOT NULL,  -- RQ job ID
    task_name VARCHAR(255) NOT NULL,
    status VARCHAR(50) DEFAULT 'queued',
    args JSONB,
    result JSONB,
    enqueued_at TIMESTAMPTZ,
    started_at TIMESTAMPTZ,
    finished_at TIMESTAMPTZ
);
```

**deployment_logs** (streaming logs)
```sql
CREATE TABLE deployment_logs (
    id BIGSERIAL PRIMARY KEY,
    deployment_id INT REFERENCES deployments(id),
    job_id VARCHAR(255) REFERENCES jobs(job_id),
    step VARCHAR(100),
    message TEXT,
    level VARCHAR(20) DEFAULT 'info',  -- info, warning, error
    created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_deployment_logs_deployment_id ON deployment_logs(deployment_id, created_at);
```

**cluster_state** (final cluster info)
```sql
CREATE TABLE cluster_state (
    cluster_id INT PRIMARY KEY REFERENCES clusters(id),
    nodes JSONB NOT NULL,  -- array of node states (Talos + K8s)
    kubeconfig TEXT NOT NULL,
    metallb_address_pool CIDR[],
    traefik_ip INET,
    kubernetes_version VARCHAR(50),
    network_cidr CIDR,
    service_cidr CIDR,
    last_updated TIMESTAMPTZ DEFAULT NOW()
);
```

---

## API Design (FastAPI)

### Endpoints

**Web Pages** (HTML responses)
- `GET /` - Landing page with cluster status and "Deploy" button
- `GET /deploy` - Deployment review page
- `GET /deploy/run` - Active deployment page with live logs
- `GET /cluster` - Cluster info page (after deployment)
- `GET /health` - Health check

**REST API** (JSON)
- `POST /api/cluster` - Create/update cluster configuration
  - Body: `{name, network_bridge, network_cidr, network_gateway, ip_range_start, ip_range_end}`
  - Returns: cluster ID
- `GET /api/cluster/{id}` - Get cluster details
- `GET /api/cluster/{id}/review` - Get auto-generated deployment plan
- `POST /api/cluster/{id}/deploy` - Start deployment
  - Body: `{}`
  - Returns: deployment ID
- `GET /api/deployment/{id}/status` - Get deployment status
- `GET /api/deployment/{id}/logs` - Get logs (with pagination/streaming)
- `GET /api/deployment/{id}/logs/stream` - Server-Sent Events stream
- `GET /api/cluster/{id}/kubeconfig` - Download kubeconfig file
- `POST /api/deployment/{id}/cancel` - Cancel running deployment

### Request Flow

1. `POST /api/cluster` → creates cluster record with status "configuring"
2. User visits `/deploy` → web calls `GET /api/cluster/{id}/review` → returns VM plan
3. User confirms → `POST /api/cluster/{id}/deploy` → creates deployment record, enqueues RQ jobs
4. Frontend opens `/deploy/run?deployment_id=X` → polls `GET /api/deployment/X/status` or streams `/api/deployment/X/logs/stream`
5. Completion → redirect to `/cluster` → download kubeconfig

---

## Deployment Task Sequence (RQ Workers)

Each deployment consists of sequential async tasks:

### Task 1: `discover_proxmox`
**Input**: cluster_id, proxmox credentials
**Actions**:
- Connect to Proxmox API
- Query all nodes: status, resources, network bridges
- Update `vm_plans` with discovered topology
- Log: "Discovered Proxmox cluster: 3 nodes (pve1, pve2, pve3)"
**Output**: placement plan (which VM on which node)

### Task 2: `size_vms`
**Input**: cluster_id, placement plan
**Actions**:
- Calculate resource requirements based on auto-sizing algorithm
- Create `vm_plans` entries for:
  - Management VM: fixed 2 CPU, 4GB RAM, 32GB disk (on lease-loaded node)
  - Control plane VMs: 2 CPU, 4GB RAM each (spread across distinct nodes)
  - Worker VMs: remaining resources distributed evenly
- Allocate IPs from configured range (or DHCP)
- Log: "VM plan: 1 management, 3 controlplane, 4 workers"
**Output**: complete `vm_plans` table

### Task 3: `create_talos_vms`
**Input**: cluster_id, vm_plans
**Actions**:
- For each Talos VM (skip management, already exists):
  - Download Talos ISO (if not cached)
  - Create VM via Proxmox API with specified resources, CPU type, machine type
  - Add ISO as CD-ROM
  - Configure network bridge, MAC address, IP if static
  - Set cloud-init for initial Talos config injection (optional, or use talosctl later)
  - Start VM
  - Wait for OS to boot (probe QGA or ping)
  - Log: "Created VM talos-cp-1 on pve1"
- Update VM IDs in database
**Output**: Talos VMs running, IPs known

### Task 4: `wait_for_talos`
**Input**: cluster_id, vm_plans
**Actions**:
- For each Talos node:
  - Wait for node to be reachable on network (ping or port 50000)
  - Wait for Talos API to be ready (probe port 50443)
  - Retry for up to 10 minutes
  - Log: "Node talos-cp-1 ready"
**Output**: All Talos nodes responsive

### Task 5: `generate_talos_configs`
**Input**: cluster_id
**Actions**:
- Fetch Talos machine config using `talosctl gen config`
- Modify for cluster name, endpoint (first control plane IP), CNI (Calico), pod/service CIDRs
- Split into controlplane and worker configs
- Store in `/opt/twinbox/config/talos/`
- Log: "Generated Talos configuration"
**Output**: Talos config files ready

### Task 6: `apply_talos_config`
**Input**: cluster_id
**Actions**:
- For each control plane node (in order):
  - Apply Talos config via `talosctl apply-config --machine <ip> --file controlplane.yaml --wait`
  - Log: "Applied Talos config to talos-cp-1, waiting for bootstrap..."
- For each worker node (parallel):
  - Apply Talos config
  - Log: "Applied Talos config to talos-worker-1"
**Output**: Talos nodes configured with Kubernetes components

### Task 7: `bootstrap_kubernetes`
**Input**: cluster_id
**Actions**:
- Get first control plane node IP
- Run `talosctl bootstrap --nodes <ip>`
- Wait for control plane to initialize (probe Kubernetes API)
- Generate kubeconfig: `talosctl kubeconfig --output /opt/twinbox/config/kubeconfig`
- Log: "Kubernetes bootstrapped, control plane ready"
**Output**: Kubernetes API available, kubeconfig saved

### Task 8: `wait_for_workers`
**Input**: cluster_id
**Actions**:
- Poll Kubernetes API: `kubectl get nodes`
- Wait for all worker nodes to join and reach Ready state
- Timeout: 10 minutes
- Log: "All 4 worker nodes joined and Ready"
**Output**: Cluster fully joined

### Task 9: `install_cni`
**Input**: cluster_id
**Actions**:
- Apply Calico manifest: `kubectl apply -f https://projectcalico.docs.tigera.io/manifests/calico.yaml`
- Wait for Calico pods to be ready across all nodes
- Log: "Installed Calico CNI"
**Output**: Pod network operational

### Task 10: `install_metallb`
**Input**: cluster_id, network_cidr, ip_range
**Actions**:
- Create ConfigMap with IP address pool (from .200-.250 of node subnet)
- Apply MetalLB manifests (layer2 mode)
- Wait for speaker pods to be ready
- Log: "Installed MetalLB (layer2)"
**Output**: LoadBalancer services functional

### Task 11: `install_traefik`
**Input**: cluster_id
**Actions**:
- Apply Traefik deployment (Deployment + Service LoadBalancer)
- Wait for Traefik pods to be ready
- Wait for Service to acquire LoadBalancer IP from MetalLB
- Retrieve LoadBalancer IP
- Store in `cluster_state.traefik_ip`
- Log: ✅ Installed Traefik ingress at 192.168.1.200"
**Output**: Ingress controller ready

### Task 12: `deployment_complete`
**Input**: cluster_id, deployment_id
**Actions**:
- Update `clusters.status` = "deployed"
- Update `deployments.status` = "succeeded", `completed_at` = NOW()
- Log: 🎉 Cluster deployment complete! Kubeconfig ready for download."
**Output**: Success state

---

## Failure Handling & Retry

Each task is **idempotent** and can be retried independently:

- **Task failure**: RQ marks job as failed, logs error
- **Web UI shows**: "Failed at step: <task_name>", error message
- **User options**: "Retry from step" or "Restart deployment"
- **Cleanup**: If failure is unrecoverable (e.g., wrong configuration), user can delete cluster and start over; VMs remain in Proxmox and can be manually deleted or auto-cleaned on next deployment with same name

**State consistency**: Each task reads from DB and updates progress before starting long operations. If interrupted, the task can be safely re-run.

---

## Network Design

### Bridge Selection
- On Review page, show list of Proxmox bridges (queried from API)
- Default: `vmbr0` or most common
- User selects one

### IP Allocation Strategy
Two modes:

**DHCP Mode** (default for simplicity):
- VMs use DHCP from Proxmox bridge network
- Management VM already has IP (shown on screen)
- Talos VMs get IPs automatically
- Talos configs use those discovered IPs

**Static Mode** (user provides):
- User enters: CIDR (e.g., `192.168.1.0/24`), gateway, IP range (e.g., `192.168.1.150-200`)
- System allocates sequential IPs from range
- Proxmox bridge must be configured for static routing or have DHCP reservations

### Services Networking
- Kubernetes API: on node IPs (talos control plane IPs)
- MetalLB pool: same subnet, addresses `200-250` (configurable)
- Traefik LoadBalancer: gets IP from MetalLB pool
- Pod network: Calico default `192.168.0.0/16` (configurable)
- Service network: `10.96.0.0/12` (K8s default, configurable)

---

## Security Model

### Proxmox
- Dedicated user `twinbox@pve` with token-based auth
- Limited to resource pool `twinbox-<cluster-name>`
- Permissions: VM lifecycle only, no storage, no user management, no audit

### Management VM
- Runs as `twinbox` user (non-root) inside containers
- Port 8080 bound to all interfaces (no firewall initially; user can configure)
- No external network access required except to Proxmox API
- Secrets:
  - `proxmox-creds.yaml`: Proxmox API token
  - `SECRET_KEY`: for encrypting stored credentials, used by FastAPI
  - `DB_PASSWORD`: PostgreSQL password
- All mounted in Docker volumes with appropriate permissions

### Kubernetes Cluster
- Talos nodes: API only accessible via client certificates from management VM
- No SSH allowed
- Calico network policies provide isolation by default
- MetalLB advertises only on configured interface
- Traefik dashboard not exposed by default (optional password protection)

### Web UI
- No authentication initially (runs on isolated management network)
- Future: simple password auth or OIDC
- All API endpoints require same-origin or CORS controlled

---

## UI/UX Design

### Landing Page (`/`)
```
┌────────────────────────────────────────────────────────┐
│ Twinbox - Kubernetes on Proxmox                        │
├────────────────────────────────────────────────────────┤
│                                                        │
│  Cluster: production                                  │
│  ✓ Proxmox: Connected (3 nodes)                      │
│  ✓ Management VM: Running                            │
│                                                        │
│  [ Deploy Complete Cluster ]                         │
│                                                        │
│  Powered by Twinbox                                   │
└────────────────────────────────────────────────────────┘
```

### Review Page (`/deploy`)
```
┌────────────────────────────────────────────────────────┐
│ Back  Deploy Cluster                                  │
├────────────────────────────────────────────────────────┤
│                                                        │
│ Auto-detected Resources                              │
│ • Proxmox Cluster: 3 nodes (pve1, pve2, pve3)       │
│ • Free Resources: 12 CPUs, 32GB RAM, 1.2TB disk     │
│                                                        │
│ Network                                              │
│ • Bridge: vmbr0                                      │
│ • IP Assignment: DHCP                                │
│                                                        │
│ Deployment Plan                                      │
│ ┌──────────────────────────────────────────────┐    │
│ │ VM Name              Host   CPU  RAM  Disk   │    │
│ ├──────────────────────────────────────────────┤    │
│ │ twinbox-mgmt-1       pve1   2    4GB  32GB  │    │
│ │ talos-cp-1           pve1   2    4GB  50GB  │    │
│ │ talos-cp-2           pve2   2    4GB  50GB  │    │
│ │ talos-cp-3           pve3   2    4GB  50GB  │    │
│ │ talos-worker-1       pve1   2    4GB  50GB  │    │
│ │ talos-worker-2       pve2   2    4GB  50GB  │    │
│ │ talos-worker-3       pve3   2    4GB  50GB  │    │
│ └──────────────────────────────────────────────┘    │
│                                                        │
│  [ Modifications ]  [ Start Deployment ]             │
└────────────────────────────────────────────────────────┘
```

**Modifications modal**:
- Override CPU/RAM/disk per role
- Change control plane count (1,3,5) and worker count
- Edit network settings (bridge, static IP range)
- Edit placement preferences (pin VMs to specific nodes)

### Deployment Page (`/deploy/run`)
```
┌────────────────────────────────────────────────────────┐
│ Deploying...                                          │
├────────────────────────────────────────────────────────┤
│                                                        │
│ Progress:                                             │
│ ☐ Discover Proxmox           ✅ Complete             │
│ ☐ Create Talos VMs          ⏳ Running (3/6)       │
│ ☐ Configure Talos           ⬜ Not started          │
│ ☐ Bootstrap Kubernetes      ⬜ Not started          │
│ ☐ Install CNI               ⬜ Not started          │
│ ☐ Install MetalLB           ⬜ Not started          │
│ ☐ Install Traefik           ⬜ Not started          │
│                                                        │
│ ┌────────────────────────────────────────────────┐   │
│ │ Creating VM: talos-cp-1                        │   │
│ │ • Creating VM ID 102                          │   │
│ │ • Configuring CPU, RAM, disk                 │   │
│ │ • Adding ISO: talos-amd64.iso                 │   │
│ │ • Setting network bridge: vmbr0              │   │
│ │ • Starting VM...                             │   │
│ │ ✓ VM created successfully                    │   │
│ │                                                │   │
│ │ Creating VM: talos-cp-2                       │   │
│ │ • Creating VM ID 103                          │   │
│ └────────────────────────────────────────────────┘   │
│                                                        │
│ Estimated remaining: 4 minutes                        │
│                                                        │
│ [ View Logs ] [ Cancel ]                              │
└────────────────────────────────────────────────────────┘
```

### Complete Page (`/cluster`)
```
┌────────────────────────────────────────────────────────┐
│ 🎉 Cluster Ready!                                     │
├────────────────────────────────────────────────────────┤
│                                                        │
│  Cluster: production                                  │
│  Kubernetes: v1.28.0                                  │
│  Nodes: 7 (3 control-plane, 4 workers)               │
│                                                        │
│  Ingress: Traefik                                     │
│  LoadBalancer IP: 192.168.1.200                      │
│  Dashboard: http://192.168.1.200:8080 (optional)    │
│                                                        │
│  [ Download kubeconfig ]                             │
│                                                        │
│  Next steps:                                          │
│  • Use kubectl with the downloaded config           │
│  • Deploy applications via Traefik ingress          │
│  • Access services at http://<traefik-ip>           │
│                                                        │
│  [ View Cluster Health ]                             │
└────────────────────────────────────────────────────────┘
```

---

## Implementation Plan

### Phase 1 Implementation Tasks

1. **Proxmox bootstrap script** (`setup-wizard.sh`)
   - Bash script with read prompts
   - Proxmox API calls via `pvesh` or `curl`
   - User and permission creation
   - VM creation with cloud-init
   - IP detection
   - ~200 lines, well-commented

2. **Ubuntu cloud-init template**
   - Installs Docker, docker-compose
   - Clones Twinbox repo (or downloads tarball)
   - Sets up environment
   - Builds and starts containers
   - Configures systemd for restart

3. **Docker-compose configuration**
   - Services: postgres, redis, web, worker
   - Volume mappings
   - Network configuration
   - Environment variable handling

4. **Database migrations**
   - SQLAlchemy models matching schema
   - Alembic migrations for schema evolution
   - Seed data for initial cluster

5. **FastAPI application**
   - API endpoints as defined
   - HTML templates (Jinja2) with HTMX
   - Database session management
   - Authentication middleware (future)

6. **RQ worker implementation**
   - Task functions (12 tasks as above)
   - Error handling and retry logic
   - Progress logging to DB
   - Idempotency guarantees

7. **Proxmox API wrapper**
   - Python class for Proxmox REST API
   - Authentication with token
   - Methods: list nodes, create VM, get VM status, etc.
   - Error handling

8. **Placement engine**
   - Algorithm to distribute VMs across nodes
   - Resource calculation and validation
   - IP allocation logic
   - Tolerance for node failures

9. **Talos integration**
   - Wrapper around `talosctl` commands
   - Config generation using templates
   - Apply with wait and verification
   - Bootstrap and kubeconfig retrieval

10. **Kubernetes operations**
    - kubectl wrapper for CNI/MetalLB/Traefik installation
    - Wait loops for pod readiness
    - Error detection and reporting

11. **Frontend (HTMX + Tailwind)**
    - Landing, review, deployment, complete pages
    - SSE log streaming
    - Progress indicators
    - Modal for plan modifications
    - Responsive design

12. **Testing and validation**
    - Unit tests for placement engine
    - Integration tests for task flow (mocked Proxmox)
    - End-to-end test script
    - Validation script for Phase 1 dependencies

---

## Future Enhancements (Not in V1)

- ✅ HTTPS for web UI (Let's Encrypt)
- ✅ Authentication (password, OIDC)
- ✅ Cluster dashboard (Headlamp integration)
- ✅ Backup and restore
- ✅ Multiple cluster management from single Management VM
- ✅ Upgrade Kubernetes/CNI
- ✅ Scaling: add/remove worker nodes
- ✅ Monitoring stack (Prometheus, Grafana, AlertManager)
- ✅ Logging stack (Loki)
- ✅ Service mesh (Istio, Linkerd)
- ✅ GitOps (ArgoCD, Flux)
- ✅ Cloudflare Tunnel / Tailscale integration
- ✅ ISO caching to avoid re-downloads
- ✅ ARM64 support

---

## Success Criteria

**User can achieve the following in < 15 minutes**:

1. Run the bootstrap script on Proxmox console
2. Open browser to http://<management-vm-ip>:8080
3. See auto-generated cluster plan (correct sizing, placement)
4. Click "Start Deployment"
5. Watch real-time logs
6. Download kubeconfig
7. Run `kubectl get nodes` and see all nodes Ready
8. Deploy a test app and access via Traefik LoadBalancer IP

**No manual intervention required** between step 1 and step 6.

---

## Conclusion

This design achieves the goal of **enormous simplification** while maintaining production-ready features. The user makes only one decision (cluster name) initially, and optionally reviews/confirms the auto-generated plan. Everything else is automatic, observable, and reliable.

The containerized architecture with PostgreSQL ensures state persistence and recoverability. The modular task system allows easy enhancement and debugging. The intelligent resource discovery and placement make it work on any Proxmox environment without guesswork.

Ready to implement?
