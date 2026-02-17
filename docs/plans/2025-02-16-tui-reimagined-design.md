# Twinbox Textual TUI Design

**Date**: 2025-02-16
**Branch**: feature/tui-reimagined
**Status**: Draft

This document outlines the design for a modern Text-based User Interface (TUI) for Twinbox, replacing the current bash wizard with an interactive, polished experience.

---

## 1. Architecture Overview

### 1.1 Core Concept

A single Python application built with the [Textual](https://textual.textualize.io/) framework that runs directly on the Proxmox VE host. The application provides:

- **Dashboard**: Main screen showing cluster status, quick actions, and system health
- **Wizard**: Guided multi-screen workflow for creating new clusters
- **Unified execution**: Both Phase 1 (VM creation) and Phase 2 (manager installation) are automated and executed from within the TUI

### 1.2 Technical Stack

- **Framework**: Textual 0.44+ (based on asyncio)
- **Proxmox integration**: Reuse existing `manager/shared/proxmox.py` (copied with minimal modifications)
- **SSH**: asyncssh for Phase 2 remote execution
- **State persistence**: SQLite (local file: `~/.local/share/twinbox/tui-state.db`)
- **Configuration**: pydantic-settings with YAML support
- **Styling**: Textual CSS for theming

### 1.3 Deployment Model

```
┌─────────────────────────────────────────────────────────────┐
│                    Proxmox VE Host                          │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │          Twinbox TUI (Python + Textual)            │   │
│  │  ┌─────────────┐  ┌─────────────┐                 │   │
│  │  │  Dashboard  │  │    Wizard   │                 │   │
│  │  └─────────────┘  └─────────────┘                 │   │
│  │         │                   │                       │   │
│  │         ▼                   ▼                       │   │
│  │  ┌──────────────────────────────────────┐           │   │
│  │  │   State Manager (SQLite)            │           │   │
│  │  └──────────────────────────────────────┘           │   │
│  │         │                                           │   │
│  │         ▼                                           │   │
│  │  ┌──────────────────────────────────────┐           │   │
│  │  │   Deployment Executor                │           │   │
│  │  │  ┌─────────────┐  ┌─────────────┐   │           │   │
│  │  │  │  Phase 1    │  │  Phase 2    │   │           │   │
│  │  │  │ (Proxmox    │  │ (SSH to    │   │           │   │
│  │  │  │  API)       │  │  VM)       │   │           │   │
│  │  │  └─────────────┘  └─────────────┘   │           │   │
│  │  └──────────────────────────────────────┘           │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │          New Management VM (Ubuntu)                │   │
│  │  ┌───────────────────────────────────────────────┐ │   │
│  │  │ Twinbox Manager (Docker Compose)              │ │   │
│  │  │  ┌──────────┐  ┌──────────┐                  │ │   │
│  │  │  │  Web UI  │  │  Worker  │                  │ │   │
│  │  │  │ :8080    │  │ (RQ)     │                  │ │   │
│  │  │  └──────────┘  └──────────┘                  │ │   │
│  │  └───────────────────────────────────────────────┘ │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. Dashboard Design

### 2.1 Layout

```
┌─────────────────────────────────────────────────────────────────┐
│ Twinbox [Connected: pve3]  ████ Clusters  ●  Deployments  ? │
├─────────────┬───────────────────────────────────────────────┤
│             │  ## Clusters                                 │
│  QUICK      │  ┌───────────────────────────────────────┐ │
│  ACTIONS    │  │  Name         Status   IP  █ Nodes   │ │
│             │  │  ─────────────────────────────────── │ │
│  [n] New    │  │  twinbox-demo running  ✓✓✓   3/3/5  │ │
│  Deployment │  │  prod-k8s     ready   ✓✓✓   3/3/0  │ │
│             │  │  test-cluster failed   ✓✓✗   1/3/0  │ │
│  [v] View   │  │  staging      pending ✓✓   -/-/-   │ │
│  Logs       │  └───────────────────────────────────────┘ │
│             │                                               │
│  [r] Retry  │  ## System Health                            │
│  [d] Delete │  CPU: 64 cores | RAM: 256GB | Storage: 2.8TB │
│             │                                               │
│  [r] Refresh│                                               │
│             │                                               │
│  [?] Help   │                                               │
└─────────────┴───────────────────────────────────────────────┘
│ Status: Dashboard loaded | Last refresh: 2s ago            │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 Components

1. **Header Bar**: App title, connection indicator, cluster count, quick status
2. **Left Sidebar** (Optional or collapsible):
   - Quick action buttons (New, View Logs, Retry, Delete)
   - System health summary
3. **Main Content**: DataTable showing clusters with columns:
   - Name
   - Status (with color badges: Running, Deployed, Error, Pending)
   - Management VM IP
   - Control Plane nodes (✓/✗ count)
   - Worker nodes (count)
   - Created date
4. **Footer**: Status bar with current operation, last refresh time, keyboard hints

### 2.3 Interactions

- **F5 / [r] Refresh**: Reload cluster data from database and Proxmox API
- **Enter / Double-click**: Open cluster details or context menu
- **Selection**: Row selection enables context-sensitive actions
- **Auto-refresh**: Every 30 seconds, updates status from live Proxmox data

---

## 3. Wizard Design

### 3.1 Multi-Screen Flow

The wizard is a linear, guided workflow with back/forward navigation:

```
Wizard: Create New Cluster
┌─────────────────────────────────────────────────────────────┐
│ [1] Preflight  ● [2] Config  ○ [3] Review  ○ [4] Execute  │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  # Preflight Checks                                         │
│  ┌───────────────────────────────────────────────────────┐ │
│  │ ✓ Proxmox API connected                              │ │
│  │ ✓ Required packages installed                        │ │
│  │ ✓ 3 nodes online (pve1, pve2, pve3)                 │ │
│  │ ⚠ Bridge vmbr0 not found (using vmbr1)              │ │
│  │ ✓ Storage pool 'local-lvm' available                 │ │
│  │ ✓ Total resources: 64 cores, 256GB RAM, 4TB disk    │ │
│  └───────────────────────────────────────────────────────┘ │
│                                                             │
│  [< Back]                                      [Next >]    │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 Screen 1: Preflight Checks

**Purpose**: Validate host environment before proceeding.

**Checks performed**:
1. Proxmox API accessibility (test connection with provided credentials)
2. Required binaries: `qm`, `pvesh`, `cloud-localds`, `virt-customize`
3. Node count and online status
4. Available storage pools
5. Network bridges (look for default)
6. Total CPU/RAM/disk capacity
7. SSH connectivity (test to localhost if needed)

**Display**: Grid of check results with icons (✓ ✓, ✗, ⚠). Hover shows details. Warnings allow proceed; failures block navigation.

**Auto-run**: Checks execute when screen becomes active. Results cached for back/forward navigation.

---

### 3.3 Screen 2: Configuration Form

**Purpose**: Collect all user inputs needed for cluster deployment.

**Form fields**:

| Field | Type | Default | Validation |
|-------|------|---------|------------|
| Cluster name | Text | none | Required, alphanumeric + hyphens, no spaces |
| SSH public key | Large textarea | empty | Optional |
| Management VM CPU | Select/Slider | 2 | 1-16 |
| Management VM RAM (MB) | Number/Slider | 4096 | 2048-65536 |
| Management VM Disk (GB) | Number/Slider | 32 | 8-512 |
| Control plane count | Select | 3 | 1, 3, 5 |
| Worker count | Number | 0 | 0-100 |
| Node selection | Multi-select | all nodes | At least as many as CP count |
| Storage pool | Select | local-lvm | From preflight |
| Network bridge | Text | vmbr0 | From preflight |

**Layout**: Grouped sections:
- **General**: Cluster name, SSH key
- **Management VM**: CPU, RAM, disk sliders
- **Cluster Topology**: CP count, worker count, node selection
- **Networking**: Bridge, IPAM mode (DHCP only for MVP)

**Reactive validation**:
- Cluster name validated in real-time
- Resource summary updates: "Will allocate: 2 (mgmt) + 3 (CP) + 0 (worker) = 5 VMs, ~20 GB RAM"
- Node selection warns if not enough nodes for CP count

**Dynamic behavior**: Selecting nodes shows available resources per node (CPU, RAM, free disk).

---

### 3.4 Screen 3: Review & Confirm

**Purpose**: Present summary for user confirmation before execution.

**Content**:

```
## Configuration Summary

**Cluster**: twinbox-demo
**Nodes**: pve1, pve2, pve3
**Management VM**:
  - VM ID: 101 (auto-selected)
  - 2 CPU, 4GB RAM, 32GB disk
  - Node: pve1, Bridge: vmbr0
**Control Planes** (3 nodes):
  - pve2: 2 CPU, 4GB RAM each
  - pve3: 2 CPU, 4GB RAM each
  - pve1: 2 CPU, 4GB RAM each
**Workers**: (0)

**Credentials**:
  - Proxmox user: twinbox@pve (API token generated)
  - Management VM: twinbox user (password randomized)

**SSH Key**: provided (will be added to authorized_keys)

---

⚠ This will create 4 VMs and install software. Continue?
[ ] I understand this will modify my Proxmox cluster
[ Deploy Cluster ]
```

**Actions**:
- "Back" returns to Config to edit
- "Deploy" begins execution (only if checkbox checked)

---

### 3.5 Screen 4: Execution Progress

**Purpose**: Real-time display of deployment steps with live logs.

**Layout**:

```
Current Step: Creating management VM (2/12)
Progress: ████████░░ 35%

Recent Output:
  [INFO] Discovering cluster-wide VM IDs...
  [INFO] Used VM IDs found: 101, 102, 150, 201
  [INFO] Using VM ID 101 (free)
  [SUCCESS] VM 101 created (empty)
  [INFO] Importing cloud image as disk...
  [INFO] Cloud-init configured

[ Pause ] [ Cancel ]
```

**Components**:
1. **Progress bar**: Overall percentage (Phase 1: 0-50%, Phase 2: 50-100%)
2. **Current step label**: Human-readable description of current operation
3. **Log viewer**: Scrollable RichLog widget with color-coded output (INFO, SUCCESS, WARNING, ERROR)
4. **Control buttons**: Pause/Resume (pauses log auto-scroll), Cancel (with confirmation)

**Real-time updates**:
- DeploymentExecutor calls callbacks as each milestone completes
- Each sub-step logs to both the viewer and the database
- Auto-scroll to bottom; user can scroll back

---

### 3.6 Screen 5: Completion

**Purpose**: Show final result and next steps.

**Success state**:

```
✓ Cluster Deployed Successfully!

Management VM: twinbox-mgmt-twinbox-demo
  VM ID: 101
  IP: 192.168.1.105

Twinbox Manager: http://192.168.1.105:8080
  - Username: admin (configured on first login)
  - Check /opt/twinbox/config/admin.env for initial password

Kubeconfig: ~/.kube/twinbox-demo.config (generated)

Next steps:
  1. Access web UI to create Kubernetes clusters
  2. Run `twinbox-tui` to manage clusters from dashboard

[ Open Web UI ] [ Deploy Another Cluster ] [ View Logs ]
```

**Failure state**:

```
✗ Deployment Failed

Step: Starting Docker services (Phase 2, step 8/10)
Error: Connection refused - Docker daemon not responding

Recommendation: Check SSH connectivity, Docker installation.
Logs saved to: ~/.local/share/twinbox/logs/deploy-abc123.log

[ Retry (from failed step) ] [ View Full Logs ] [ Start Over ]
```

---

## 4. Phase 2 Execution Flow

After the management VM is created and running (Phase 1), the TUI automatically begins Phase 2 via SSH.

### 4.1 SSH Connection

- Library: `asyncssh` (async-native, fits Textual)
- Connection parameters:
  - Host: Management VM IP (from Phase 1)
  - User: `twinbox`
  - Authentication: Password (randomly generated) OR SSH key (if user provided)
- Connection pooling: single persistent connection reused for all commands
- Timeout: 30 seconds per command, 60 seconds for connection

### 4.2 Sequential Steps

Phase 2 steps run sequentially; each must succeed before the next. Steps are:

1. **Wait for SSH**: Poll until SSH port is accepting connections
2. **Clone repository**:
   ```bash
   if [ ! -d /opt/twinbox ]; then
     git clone https://github.com/yourorg/Twinbox.git /opt/twinbox
   fi
   ```
3. **Create environment config**:
   - Copy `/opt/twinbox/manager/.env.example` to `.env`
   - Write `/opt/twinbox/config/proxmox-creds.yaml` with credentials from Phase 1
   - Generate random `SECRET_KEY` if not present
   - Set `DATABASE_URL=postgresql://...` (constructed from credentials)
4. **Install dependencies**:
   ```bash
   cd /opt/twinbox
   pip install -r requirements-test.txt
   ```
5. **Initialize database**:
   ```bash
   python3 -c "from manager.shared.database import init_db; init_db()"
   alembic upgrade head
   ```
6. **Start PostgreSQL and Redis**:
   ```bash
   docker-compose up -d postgres redis
   # Wait 10 seconds for health
   ```
7. **Start Web and Worker**:
   ```bash
   docker-compose up -d web worker
   ```
8. **Verify services**:
   ```bash
   curl -f http://localhost:8080/health
   curl -f http://localhost:8080/health?component=worker
   ```
9. **Generate kubeconfig** (TODO: is this part of Talos deployment later?):
   - Not needed for Phase 2 (manager only)
10. **Finalize**: Write success marker file `/opt/twinbox/.installed`

### 4.3 Error Handling & Retry

- **Transient failures** (network timeout, command timeout): automatic retry up to 3 times with exponential backoff
- **Permanent failures** (command exit code != 0):
  - Log full stderr
  - Update deployment status to `failed`
  - Prompt user: Retry (from same step), Skip (continue), or Abort
- **SSH disconnection**: Attempt reconnect; if persistent, abort and show error
- **Checkpoints**: After each step completes successfully, record in database. If deployment is resumed, executor queries last successful step and continues from there.

### 4.4 Log Streaming

All SSH command output is streamed in real-time:
- Each line is classified (INFO, WARNING, ERROR) based on patterns
- Sent to Textual `LogViewer` widget via async message passing
- Also appended to a log file (`~/.local/share/twinbox/logs/deploy-<id>.log`)
- Upon completion, full log is attached to the deployment record

---

## 5. State Management

### 5.1 SQLite Schema

Three main tables:

**`clusters`**
```sql
CREATE TABLE clusters (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    status TEXT NOT NULL, -- 'deployed', 'failed', 'installing', 'pending'
    config_json TEXT NOT NULL, -- full wizard config
    management_vm_id INTEGER,
    management_ip TEXT,
    credentials_file TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

**`deployments`**
```sql
CREATE TABLE deployments (
    id TEXT PRIMARY KEY,
    cluster_id TEXT NOT NULL REFERENCES clusters(id) ON DELETE CASCADE,
    phase1_completed BOOLEAN DEFAULT FALSE,
    phase2_completed BOOLEAN DEFAULT FALSE,
    current_step INTEGER,
    progress REAL, -- 0-100
    status TEXT NOT NULL, -- 'running', 'success', 'failed', 'cancelled'
    error_message TEXT,
    started_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    completed_at TIMESTAMP
);
```

**`deployment_logs`**
```sql
CREATE TABLE deployment_logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    deployment_id TEXT NOT NULL REFERENCES deployments(id) ON DELETE CASCADE,
    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    level TEXT, -- 'INFO', 'WARNING', 'ERROR', 'SUCCESS'
    message TEXT NOT NULL
);
```

### 5.2 State Manager API

The `StateManager` class provides:

```python
class StateManager:
    def __init__(self, db_path: Path)

    # Cluster operations
    def create_cluster(config: dict) -> str  # returns cluster_id
    def get_cluster(cluster_id: str) -> Cluster
    def list_clusters() -> List[Cluster]
    def update_cluster(cluster_id: str, **kwargs) -> None

    # Deployment operations
    def create_deployment(cluster_id: str) -> str  # deployment_id
    def get_deployment(deployment_id: str) -> Deployment
    def update_deployment(deployment_id: str, **kwargs) -> None
    def get_current_deployment(cluster_id: str) -> Optional[Deployment]

    # Logging
    def add_log(deployment_id: str, level: str, message: str) -> None
    def get_logs(deployment_id: str, limit: int = 1000) -> List[LogEntry]
```

All operations are transactional. Failed operations roll back.

### 5.3 Dashboard Data Flow

On mount:
1. `StateManager.list_clusters()` → cluster records
2. For each cluster, query Proxmox API for live VM status/IP
3. Populate DataTable with merged data
4. Start timer for auto-refresh (every 30s)

---

## 6. Key Design Decisions

### 6.1 Why SQLite over JSON files?

- **Concurrency**: Multiple operations (dashboard refresh while deployment runs) safe
- **Querying**: Easy to filter/sort clusters by status, date
- **Schema evolution**: Can use Alembic later if needed
- **Single file**: Simple backup, no server required
- **Standard**: SQLite ubiquitous, no dependencies

### 6.2 Why copy Proxmox client instead of import?

The TUI runs on the Proxmox host, not inside the manager VM. Importing `manager.shared.proxmox` would require:
- Installing all manager dependencies on host (Docker, FastAPI, etc.)
- Circular dependency risk if TUI and manager share code
- Version coupling

**Decision**: Copy the relevant module (`proxmox.py`) into `twinbox-tui/` and maintain it as a fork with bug fixes pulled manually. Document this clearly.

### 6.3 Why asyncssh over paramiko?

- Native asyncio support, integration with Textual's async event loop
- Better performance for streaming command output
- Active development, modern Python support
- Cleaner API for incremental stdout/stderr reading

### 6.4 Why separate TUI directory (`twinbox-tui/`)?

- Isolated dependency set (Textual, asyncssh) from manager (FastAPI, SQLAlchemy)
- Can be developed, tested, and packaged independently
- Easier to install: `pip install twinbox-tui` vs entire manager stack
- Clear boundary: TUI is a separate tool, not a component of the manager

---

## 7. Non-Goals (Out of Scope for MVP)

- Cluster deletion wizard (manual cleanup via Proxmox UI)
- Editing existing cluster configuration (create new instead)
- Multi-cluster management from single TUI (dashboard shows all, but deployment is one at a time)
- Advanced networking: static IPs, VLANs, multiple bridges (DHCP only)
- Talos node deployment (only management VM in Phase 1/2; Kubernetes nodes are separate future work)
- Backup/restore cluster state
- Internationalization (English only)
- Docker Compose v2 plugin support fallback (assume v1)

---

## 8. Success Criteria

- [ ] TUI can complete full deployment (Phase 1 + Phase 2) end-to-end on test Proxmox
- [ ] Dashboard displays at least 5 clusters with accurate status
- [ ] Wizard screens are responsive, all表单 validate correctly
- [ ] Real-time logs stream without lag
- [ ] Cancellation cleanly aborts deployment and cleans up partial resources
- [ ] Test coverage >80% for TUI modules
- [ ] Documentation complete (README, user guide)
- [ ] Bash script still works (no breaking changes to existing functionality)

---

## 9. Open Questions

1. Should the TUI automatically check for updates/notify user of new releases?
2. Should credentials (Proxmox tokens, twinbox password) be optionally persisted for auto-reconnect, or always re-enter?
3. Does the dashboard need a "Configure" button for existing clusters (to edit config before re-deploy)?
4. Should the TUI handle the cloud-init customization with `virt-customize` or rely on cloud-init package installation? (Current bash uses both)

---

## Next Steps

1. ✅ Approve this design
2. Create implementation plan (break down into tasks, estimate)
3. Set up `twinbox-tui/` directory structure
4. Implement Phase 0: Foundation (database, config, constants)
5. Implement Phase 1: State manager, SSH executor, deployment orchestrator
6. Implement Phase 2: Textual UI (screens, widgets)
7. Integrate and test
8. Write documentation
9. Create PR for review
