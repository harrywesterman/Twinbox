# Twinbox System Architecture

## Overview

Twinbox is a platform for deploying Kubernetes clusters on Proxmox VE, featuring a three-phase deployment architecture that separates initial infrastructure bootstrap from cluster operations.

### Phased Architecture

**Phase 1 - Infrastructure Bootstrap (Wizard)**
- Runs on Proxmox host via Bash script
- Creates management VM with minimal Ubuntu, Docker, and SSH access
- Generates Proxmox credentials and cloud-init configuration
- VM boots with manager application pre-installed

**Phase 2 - Service Deployment (Manual)**
- User SSHes into management VM
- Clones repository and runs `docker-compose up -d`
- Starts Web UI (port 8080) and RQ Worker services
- Web service auto-creates Cluster record from wizard credentials

**Phase 3 - Cluster Operations (Runtime)**
- User accesses Web UI to deploy Talos Linux Kubernetes clusters
- Manager orchestrates full lifecycle: VM creation, Talos configuration, Kubernetes bootstrap
- Worker processes deployment tasks in the background with progress tracking

## Components

### Wizard Script (`wizard/setup-wizard.sh`)

The initial bootstrap automation that creates the management VM:
- **Runs on**: Proxmox host (not inside any VM)
- **Technology**: Bash with `qm`, `pvesh`, and `cloud-localds` commands
- **Responsibilities**:
  - Prompt user for cluster configuration
  - Select target Proxmox node and allocate VM ID
  - Create minimal Ubuntu VM with cloud-init
  - Generate SSH key pair for manager access
  - Store Proxmox credentials in YAML for manager consumption
- **Output**: Management VM with Docker + manager code ready to start

### Manager Application (`manager/`)

The core orchestration engine running inside the management VM, split into two services:

#### Web Service (`manager/web/`)
- **Framework**: FastAPI with Jinja2 HTML templates
- **Port**: 8080 (HTTP)
- **Responsibilities**:
  - Serve web UI for cluster deployment
  - REST API endpoints for cluster management
  - Auto-create Cluster record on startup if wizard credentials exist
  - Enqueue deployment tasks to RQ
  - Stream real-time logs via Server-Sent Events (SSE)
  - Encrypt and store credentials using Fernet

#### Worker Service (`manager/worker/`)
- **Background Processing**: RQ (Redis Queue) with multiple queues (`twinbox-high`, `twinbox-low`, `twinbox-default`)
- **Responsibilities**:
  - Execute deployment tasks sequentially
  - Query Proxmox API to provision VMs
  - Generate Talos Linux configurations
  - Bootstrap Kubernetes cluster
  - Install CNI (Calico), load balancer (MetalLB), and ingress (Traefik)
  - Update deployment progress and write structured logs

### Shared Module (`manager/shared/`)
Common utilities used by both services:
- `database.py` - SQLAlchemy 2.0 async engine, session management, base model
- `models.py` - ORM models: Cluster, VMPlan, Deployment, Job, DeploymentLog, ClusterState
- `proxmox.py` - Proxmox VE API client using API tokens (httpx with retry logic)
- `placement.py` - VM placement algorithm (bin-packing, control plane spreading)
- `talos.py` - Talos Linux configuration generation and application via `talosctl`
- `k8s.py` - Kubernetes operations (kubectl wrapper for post-bootstrap tasks)
- `security.py` - Fernet-based credential encryption/decryption

### Data Stores

#### PostgreSQL
- Stores cluster configurations, deployment records, VM plans, and job metadata
- Connection managed via SQLAlchemy async ORM
- Alembic for schema migrations (auto-upgrade on web service startup)
- All sensitive fields encrypted at rest

#### Redis
- RQ message queue for background task dispatch
- Job result storage
- Session and caching layer
- Web service checks Redis health on startup

## Deployment Flow

Twinbox follows a three-phase architecture:

### Phase 1: Bootstrap (Wizard)

1. User runs `wizard/setup-wizard.sh` on Proxmox host
2. Wizard prompts for: cluster name, management VM resources, CPU/RAM/disk, SSH key, Proxmox credentials
3. Wizard selects target node, finds available VM ID, and creates minimal Ubuntu VM with cloud-init
4. VM boots with Docker and manager code pre-installed via cloud-init
5. Wizard generates `/opt/twinbox/config/proxmox-creds.yaml` inside the VM with encrypted credentials
6. Management VM is ready for Phase 2

### Phase 2: Service Startup (Manual)

1. User SSHes to management VM
2. Runs `git clone <repository>` and `cd Twinbox`
3. Executes `docker-compose up -d` (or `make install` then `docker-compose up -d web worker`)
4. PostgreSQL and Redis containers start first
5. Web service starts, runs Alembic migrations, detects credentials file
6. Web service auto-creates Cluster record in database using wizard credentials
7. Worker service starts and connects to Redis
8. System ready for Phase 3

### Phase 3: Cluster Deployment (Runtime)

1. User accesses `http://<mgmt-vm-ip>:8080` in browser
2. In Web UI, user specifies:
   - Talos cluster configuration (control plane count, worker count, resources)
   - Proxmox node selection and storage settings
3. User clicks "Deploy" → Web service creates `Deployment` record with initial progress state
4. Web service calls `optimize_placement()` to calculate VM placement across Proxmox nodes
5. Enqueues task chain to RQ:
   - `discover_proxmox`: Query Proxmox for node topology and resource availability
   - `size_vms`: Calculate resource allocations for each VM role (management, control plane, workers)
   - `create_talos_vms`: Create VMs via Proxmox API with cloud-init for Talos
   - `wait_for_talos`: Poll QEMU guest agent for Talos node readiness
   - `generate_talos_configs`: Generate Talos configurations per node using `talosctl gen config`
   - `apply_talos_config`: Apply configurations to control plane sequentially, then workers in parallel
   - `bootstrap_kubernetes`: Bootstrap Kubernetes via `talosctl bootstrap`
   - `wait_for_workers`: Wait for worker nodes to join the cluster
   - `install_cni`: Install Calico CNI
   - `install_metallb`: Configure MetalLB address pool
   - `install_traefik`: Install Traefik ingress controller
   - `deployment_complete`: Finalize cluster state and mark deployment successful
6. Worker executes tasks sequentially, updating `Deployment.progress` percentage and writing logs to `DeploymentLog` table
7. Web UI streams logs via SSE as tasks complete
8. On success, Web UI displays kubeconfig and cluster details; deployment record marked complete

## Data Flow

```
┌──────────────────┐
│   Proxmox Host   │
│  (Physical/VM)   │
└────────┬─────────┘
         │ wizard/setup-wizard.sh
         │ (Phase 1)
         ▼
┌─────────────────────────────────────────┐
│  Management VM (Ubuntu + Docker)        │
│  - PostgreSQL (persistent data)         │
│  - Redis (message queue)                │
│  - Web Service (FastAPI:8080)           │
│  - Worker (RQ)                          │
│  - /opt/twinbox/config/proxmox-creds.yaml │
└─────────────┬───────────────────────────┘
               │ SSH + git clone + docker-compose up
               │ (Phase 2)
               ▼
┌─────────────────────────────────────────┐
│  Twinbox Manager Running                │
│  - Auto-create Cluster from creds file  │
│  - Web UI accessible on port 8080       │
└─────────────┬───────────────────────────┘
               │ User accesses UI, creates deployment
               │ (Phase 3)
               ▼
┌─────────────────────────────────────────┐
│  Deployment Execution via Worker Tasks  │
│  1. Discover Proxmox topology           │
│  2. Optimize VM placement               │
│  3. Create Talos VMs                    │
│  4. Wait for Talos boot                 │
│  5. Generate & apply Talos configs      │
│  6. Bootstrap Kubernetes                │
│  7. Install CNI, MetalLB, Traefik       │
│  8. Mark deployment complete            │
└─────────────┬───────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────┐
│  Kubernetes Cluster (Talos Linux)       │
│  - Running on Proxmox VMs               │
│  - Managed by Talos                     │
│  - kubeconfig provided to user          │
└─────────────────────────────────────────┘
```

### Bootstrap Sequence

1. **Wizard creates credentials**: The setup wizard generates `proxmox-creds.yaml` containing API token credentials needed by the manager to communicate with Proxmox. This file is placed in `/opt/twinbox/config/` inside the management VM.

2. **Manager auto-initialization**: When the Web service starts, it checks for the presence of `proxmox-creds.yaml`. If found, it automatically:
   - Loads credentials and decrypts them
   - Creates a `Cluster` database record representing the Proxmox environment
   - Establishes connectivity to the Proxmox API
   - Makes the system ready for user deployments

3. **Manual service startup**: The management VM does not auto-start the manager. Users must SSH in and run `docker-compose up -d` to launch PostgreSQL, Redis, Web, and Worker services. This manual step separates infrastructure provisioning from application deployment.

## Database Schema

Key tables defined in `manager/shared/models.py`:

- **Cluster**: Represents a Proxmox-connected environment; stores credentials reference, name, and metadata
- **VMPlan**: VM specifications per cluster; includes role (management/controlplane/worker), CPU, RAM, disk, and assigned node
- **Deployment**: Tracks a single cluster deployment operation; includes progress (0-100), current step, and final status
- **Job**: Links RQ job IDs to deployments for tracking asynchronous task execution
- **DeploymentLog**: Structured log entries (step, level, message, timestamp) associated with a deployment, streamed to UI
- **ClusterState**: Periodic snapshots of cluster health and node status (used for monitoring)

All tables use UUID primary keys. Cluster deletion cascades to related records.

## Bootstrap Process

The manual Phase 2 startup process:

1. **SSH to management VM**: Use credentials from wizard output or known SSH key
2. **Clone repository**: `git clone https://github.com/yourorg/twinbox.git`
3. **Install dependencies**: `make install` (installs Python requirements, sets up environment)
4. **Start services**: `docker-compose up -d`
   - This starts PostgreSQL, Redis, Web, and Worker containers
5. **Verify startup**: Check logs with `docker-compose logs -f web` and `docker-compose logs -f worker`
6. **Access UI**: Navigate to `http://<mgmt-vm-ip>:8080` in browser
7. **Begin deployment**: Create first Kubernetes cluster via Web UI

**Note**: The wizard's cloud-init does NOT auto-start the manager; it only provisions the VM with base software and code. Manual intervention is required to start Docker Compose.

## Security

- All sensitive credentials (Proxmox tokens, SSH keys, Talos secrets) encrypted at rest using Fernet symmetric encryption
- `SECRET_KEY` environment variable (32-byte base64) required; generated if not present
- Database connections can use SSL/TLS in production environments
- No plaintext credentials appear in logs; masked secrets in `DeploymentLog`
- Proxmox API tokens used instead of passwords; limited scope and revocable

## Technology Stack

- **Backend**: Python 3.11+, FastAPI, SQLAlchemy 2.0 (async)
- **Queue**: Redis, RQ (Redis Queue)
- **Database**: PostgreSQL (containerized in management VM)
- **Container**: Docker + Docker Compose
- **OS**: Ubuntu (management VM), Talos Linux (Kubernetes nodes)
- **Kubernetes**: K3s distribution via Talos Linux
- **Configuration Management**: Talosctl for node configuration and bootstrap
- **Proxmox Integration**: Direct API via httpx (no Terraform/Ansible)
