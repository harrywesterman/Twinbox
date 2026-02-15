# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

Twinbox is a platform for deploying Kubernetes clusters on Proxmox VE. It consists of:
- **Bash wizard**: Single-command setup that creates a management VM on Proxmox
- **Manager application**: FastAPI web service + RQ worker that orchestrates cluster deployment
- **Tests**: Comprehensive unit and integration test suite

The typical workflow:
1. Run `wizard/setup-wizard.sh` on a Proxmox host → creates management VM
2. Access web UI at `http://<mgmt-vm-ip>:8080`
3. Deploy Kubernetes cluster with Talos Linux nodes

## Common Development Commands

### Initial Setup

```bash
# Create virtual environment
python3 -m venv .venv
source .venv/bin/activate

# Install dependencies
pip install -r requirements-test.txt
# or
make install

# Set up environment for manager
cd manager
cp .env.example .env  # Edit with your settings
```

### Running Tests

```bash
# All tests (unit + integration)
make test
# or
pytest tests/

# Unit tests only
make unit
# or
pytest tests/unit/

# Integration tests only
make integration
# or
pytest tests/integration/

# With coverage report
make coverage
# Opens htmlcov/index.html

# Run specific test file
pytest tests/unit/test_proxmox.py -v

# Run specific test by name
pytest -k "test_create_vm" -v

# Watch mode (requires pytest-watch)
make test-watch
```

### Database Operations

```bash
# Initialize database (creates tables)
python3 -c "from manager.shared.database import init_db; init_db()"

# Run Alembic migrations
alembic upgrade head

# Create new migration after model changes
alembic revision --autogenerate -m "Description"
# Review migration in alembic/versions/ then apply
alembic upgrade head

# Rollback one migration
alembic downgrade -1

# Reset database (development only)
alembic downgrade base
alembic upgrade head
```

### Running the Application

```bash
# Using Docker Compose (recommended for full stack)
docker-compose up -d postgres redis
# Wait for health checks, then:
docker-compose up -d web worker

# View logs
docker-compose logs -f web
docker-compose logs -f worker

# Direct uvicorn (development)
cd manager
uvicorn manager.web.main:app --reload --host 0.0.0.0 --port 8000

# Run RQ worker
cd manager
rq worker twinbox-high twinbox-low twinbox-default

# Check health endpoint
curl http://localhost:8000/health
```

### Linting and Quality

```bash
# No formal linter configured yet. Recommended:
pip install black flake8 isort
black manager/ tests/
flake8 manager/ tests/
isort manager/ tests/
```

### Wizard Script

```bash
# Test the wizard (on Proxmox host or VM)
bash wizard/setup-wizard.sh

# Non-interactive mode
export CLUSTER_NAME="testcluster"
export CPU_CORES=2
export RAM_GB=4
export DISK_GB=32
bash wizard/setup-wizard.sh

# After wizard runs, check output files
cat /tmp/twinbox-creds-${CLUSTER_NAME}.env
```

## Architecture & Key Components

### High-Level Structure

```
Twinbox/
├── wizard/                    # Bash setup wizard (runs on Proxmox)
│   └── setup-wizard.sh       # Creates management VM with cloud-init
├── manager/                   # Main application (runs inside management VM)
│   ├── web/                  # FastAPI web service (port 8080)
│   │   ├── api/              # REST API routers
│   │   ├── services/         # Business logic
│   │   ├── templates/        # Jinja2 HTML templates
│   │   └── static/           # CSS/JS/images
│   ├── worker/               # RQ background worker
│   │   └── tasks.py          # Deployment task definitions
│   ├── shared/               # Shared modules
│   │   ├── database.py       # SQLAlchemy setup
│   │   ├── models.py         # ORM models (Cluster, VMPlan, Deployment, Job, etc.)
│   │   ├── proxmox.py        # Proxmox API client
│   │   ├── placement.py      # VM placement algorithm
│   │   ├── talos.py          # Talos Linux configuration
│   │   ├── k8s.py            # Kubernetes operations
│   │   └── security.py       # Credential encryption
│   ├── alembic/              # Database migrations
│   └── init/                 # Systemd service file for Docker Compose
├── tests/
│   ├── unit/
│   │   ├── test_proxmox.py   # Mocked Proxmox API tests
│   │   ├── test_placement.py # VM placement algorithm tests
│   │   └── test_database.py  # Database and model tests
│   └── integration/
│       └── test_deployment_tasks.py  # Deployment workflow tests
├── docs/
│   ├── ARCHITECTURE.md       # System design overview
│   └── wizard-guide.md       # Wizard documentation
├── scripts/
│   └── deploy.sh             # Deployment helper
├── docker-compose.yml        # Local development stack
├── Makefile                  # Test and development commands
└── README.md                 # Quick start guide
```

### Data Flow

1. **Bootstrap**: Wizard creates VM → generates Proxmox credentials → stores in `/opt/twinbox/config/proxmox-creds.yaml`
2. **Auto-create**: On startup, web service detects credentials file → creates Cluster record in database
3. **Deployment**: User clicks "Deploy" → web service creates Deployment record → enqueues RQ jobs → worker executes tasks sequentially:
   - `discover_proxmox`: Queries Proxmox for topology
   - `size_vms`: Calculates resource allocation
   - `create_talos_vms`: Creates Talos VMs via Proxmox API
   - `wait_for_talos`: Waits for Talos nodes to be ready
   - `generate_talos_configs`: Generates Talos configurations
   - `apply_talos_config`: Applies configs to nodes
   - `bootstrap_kubernetes`: Bootstraps Kubernetes
   - `wait_for_workers`: Waits for worker nodes to join
   - `install_cni`: Installs Calico
   - `install_metallb`: Installs MetalLB
   - `install_traefik`: Installs Traefik ingress
   - `deployment_complete`: Finalizes cluster state

### Database Schema

Key tables (all in `manager/shared/models.py`):
- `Cluster`: Cluster configuration and metadata
- `VMPlan`: VM specifications (per cluster, per role: management/controlplane/worker)
- `Deployment`: Deployment operation tracking with progress
- `Job`: RQ job records with status
- `DeploymentLog`: Structured log entries for deployments
- `ClusterState`: Cached cluster health snapshots

All use UUID primary keys. Relationships cascade delete on cluster deletion.

### Important Files and Patterns

**Wizard script** (`wizard/setup-wizard.sh`):
- Runs on Proxmox host, not inside manager
- Uses `qm` and `pvesh` commands
- Creates VM ID by scanning all cluster nodes (bug: currently doesn't check LXC on non-selected nodes)
- Cloud-init ISO is stored both as file and uploaded to Proxmox storage
- After VM creation, waits for IP using QEMU guest agent

**Proxmox API client** (`manager/shared/proxmox.py`):
- Uses API tokens, not password auth
- All methods wrap `httpx` with retry logic
- Key method: `create_vm()` - creates VM with Talos-specific defaults
- Key method: `get_vm_ip()` - retrieves IP via QEMU guest agent

**Placement engine** (`manager/shared/placement.py`):
- `NodeInfo`: Represents a Proxmox node with resource availability
- `ClusterConfig`: User's desired cluster configuration
- `optimize_placement()`: Returns list of `VMPlan` objects with node assignments
- Uses simple bin-packing; ensures control planes spread across nodes

**Deployment tasks** (`manager/worker/tasks.py`):
- All tasks use `@task_wrapper` decorator for error handling and logging
- Tasks are idempotent where possible (safe to retry)
- Progress updates stored in `Deployment.progress`
- Logs written to `DeploymentLog` table and streamed to web UI

**Web service startup** (`manager/web/main.py`):
- On startup: checks DB, runs Alembic migrations, checks Redis
- Auto-creates Cluster if `/opt/twinbox/config/proxmox-creds.yaml` exists (wizard bootstrap)
- Serves HTML UI on `/` and API under `/api/`

### Testing Patterns

- **Unit tests**: Mock external dependencies (HTTP, subprocess). Use `mocker` fixture from pytest-mock.
- **Integration tests**: Use in-memory SQLite (`sqlite:///:memory:`), mock Proxmox API and external commands.
- **Fixtures** defined in `tests/conftest.py`: `test_db_session`, `mock_proxmox_api`, `fake_cluster`, etc.
- Coverage focus: placement logic, Proxmox client, database transactions.

### Environment Variables

For manager services (web and worker):
- `DATABASE_URL`: PostgreSQL connection (e.g., `postgresql+psycopg2://user:pass@host/db`)
- `REDIS_URL`: Redis connection (default: `redis://redis:6379/0`)
- `SECRET_KEY`: Used for credential encryption (must be 32 bytes for Fernet)
- `PROXMOX_CREDENTIALS_PATH`: Path to YAML file with Proxmox credentials (in management VM: `/opt/twinbox/config/proxmox-creds.yaml`)
- `HOST`, `PORT`: Web service bind address (default: `0.0.0.0:8000`)
- `RELOAD`: Enable uvicorn reload (development)

For wizard:
- `CLUSTER_NAME`, `CPU_CORES`, `RAM_GB`, `DISK_GB`, `SELECTED_NODE`: Override prompts

### Known Issues and Gotchas

1. **Wizard VM ID selection bug**: The `get_vmids_from_node()` function outputs QEMU IDs then LXC IDs. When called in a process substitution loop, only the first stream is captured on non-SELECTED nodes. This causes ID collisions in multi-node clusters. Fix: combine both outputs into a single stream or use a helper function.

2. **Wizard waits for IP immediately after VM start**: The `wait_ip()` function polls QEMU guest agent, but the agent may not be ready yet. Consider adding initial delay or retry loop.

3. **Cloud-init managed drive**: Recent Proxmox versions support `--cicustom` for cloud-init drive. The wizard uses this approach (lines 519-524). Ensure `cloud-localds` is installed for ISO creation.

4. **VNC console ordering on ARM hosts**: In `manager/shared/proxmox.py`, the VNC ordering logic for ARM hosts may need adjustment if using non-x86 hardware.

5. **Database migrations in production**: The web service automatically runs `alembic upgrade head` on startup. This is convenient but could fail if migrations conflict. Monitor startup logs.

### Code Style Preferences

- Python: Follow PEP 8, 4-space indentation
- Use type hints for function parameters and return values
- Prefer explicit over implicit; avoid magic numbers (use named constants)
- Database queries: Use SQLAlchemy 2.0 style (`.execute()` instead of `.connection.execute`)
- Error handling: Raise specific exceptions (`ProxmoxAPIError`, `TalosError`, `K8sError`) rather than generic `Exception`
- Logging: Use module-level logger (`logger = logging.getLogger(__name__)`); structured logs preferred

### Proxmox API Notes

- Authentication: API tokens in format `user@pve!tokenid=tokenvalue`
- Endpoints: `/api2/json/nodes/<node>/qemu`, `/nodes/<node>/lxc`, etc.
- VM creation workflow:
  1. `qm create <vmid>` (empty VM)
  2. `qm importdisk <vmid> <image> <storage>` (import disk)
  3. `qm set <vmid> --scsi0 <storage>:<diskname>`
  4. Configure cloud-init with `--cicustom`
  5. `qm start <vmid>`
- For cloud-init, the recommended approach is `--ide2 local:cloudinit` with `--cicustom user=local:snippets/<file>`
- QEMU guest agent: `qm guest <vmid> <command>` (e.g., `network-get-interfaces`, `cmd`)

### Talos Linux Integration

- Talos configs generated by `talosctl gen config`
- Control plane configs applied sequentially; workers can be parallel
- Bootstrap: `talosctl bootstrap --nodes <first-cp-ip>`
- Kubeconfig retrieved: `talosctl kubeconfig --nodes <cp-ips> --output kubeconfig`
- The `shared/talos.py` module wraps these commands with subprocess. Ensure `talosctl` is installed in management VM (cloud-init installs it).

## Quick Reference: Adding a Feature

When adding a new API endpoint:
1. Create router in `manager/web/api/` or add to existing router
2. Add service function in `manager/web/services/` for business logic
3. Use `Depends(get_db)` for database access
4. Return Pydantic models, not raw SQLAlchemy objects
5. Add tests in `tests/unit/` or `tests/integration/`

When modifying database:
1. Update models in `manager/shared/models.py`
2. Create Alembic migration: `alembic revision --autogenerate -m "desc"`
3. Review generated migration for accuracy
4. Apply: `alembic upgrade head`
5. Add tests for new fields/relationships

When adding a deployment task:
1. Add function to `manager/worker/tasks.py` with `@task_wrapper`
2. Follow pattern: accept `deployment_id`, `log`, `update_progress` as first args
3. Fetch `deployment` and `cluster` from DB
4. Use `log(step, level, message)` to write to `DeploymentLog`
5. Call `update_progress(deployment_id, percent, step_name)`
6. Raise domain-specific exceptions (`ValueError`, `ProxmoxAPIError`, etc.) on failure
7. Add to the task sequence in web service where deployment is orchestrated

## External Resources

- Proxmox API docs: `https://<proxmox>:8006/api2/json/` (requires login)
- Talos Linux docs: https://www.talos.dev/
- FastAPI docs: https://fastapi.tiangolo.com/
- SQLAlchemy 2.0 docs: https://docs.sqlalchemy.org/

## Testing Checklist

Before committing changes:
- [ ] `make unit` passes
- [ ] `make integration` passes
- [ ] `make coverage` shows >= 80% on modified files
- [ ] Type hints present on new functions
- [ ] Docstring added for new modules/functions
- [ ] No hardcoded credentials or secrets
- [ ] Alembic migration created if models changed
- [ ] Wizard syntax validated: `bash -n wizard/setup-wizard.sh`

## SSH Skills Context

This repository includes an `ssh-remote-connection` skill configured with:
- `SSH_HOST=pve3.local.westermanonline.com`
- `SSH_USER=root`
- `SSH_KEY_PATH=/home/harry/.ssh/id_rsa`

Use the skill to run commands on the Proxmox host for testing the wizard.

## Existing Documentation

- `README.md`: Quick start and overview
- `DEPLOYMENT.md`: Detailed testing guide with troubleshooting
- `TESTING.md`: Comprehensive test execution guide
- `docs/ARCHITECTURE.md`: System design and component descriptions
- `wizard/README.md`: Wizard script documentation
- `manager/README.md`: Manager component deep dive with database models

Refer to these for user-facing information rather than duplicating in CLAUDE.md.

## License

MIT (see main LICENSE file)
