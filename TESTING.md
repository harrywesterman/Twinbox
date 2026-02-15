# Twinbox Testing Guide

This guide walks through testing Twinbox on a real Proxmox VE cluster.

## Overview

Testing is divided into two categories:

- **Unit tests**: Run automatically via pytest, mock external dependencies (Proxmox API, subprocess calls, etc.) and test individual components in isolation.
- **Integration tests**: Test the full deployment workflow using in-memory SQLite and mocked Proxmox API, verifying the end-to-end task sequence without requiring real infrastructure.
- **E2E tests (manual)**: Test the complete system on real Proxmox hardware, including the wizard, manager startup, and full Kubernetes deployment.

**Note on Cloud-Init Simplification**: The wizard now uses a simpler cloud-init approach with direct `--cicustom` configuration. This eliminates separate ISO upload steps and ensures the management VM starts with pre-injected Proxmox credentials. Docker Compose is auto-started by cloud-init, so the web UI becomes available automatically after cloud-init completes (2-5 minutes). This simplifies testing and deployment.

## Prerequisites

- **Proxmox VE 7.0+** with at least 16GB RAM, 4 CPU cores, and 200GB storage
- **Root access** to Proxmox console (SSH or Web Shell)
- **Internet access** from Proxmox host (to download Ubuntu ISO and Docker images)
- **Bridge network** configured (default `vmbr0`)

## Running Unit Tests

Unit tests are automated and should be run before any commit. They mocks external dependencies (Proxmox API, subprocess calls, etc.) and test individual components in isolation.

```bash
# Run all unit tests
make unit
# or
pytest tests/unit/

# Run with coverage
make coverage
```

Key test files:
- `tests/unit/test_proxmox.py`: Proxmox API client
- `tests/unit/test_placement.py`: VM placement algorithm
- `tests/unit/test_database.py`: Database operations and models
- `tests/unit/test_talos.py`: Talos configuration generation

## Running Integration Tests

Integration tests exercise the full deployment workflow using in-memory SQLite and mocked Proxmox API. They verify the end-to-end task sequence without requiring real infrastructure.

```bash
# Run all integration tests
make integration
# or
pytest tests/integration/

# Run specific integration test
pytest tests/integration/test_deployment_tasks.py -v
```

Integration tests use fixtures defined in `tests/conftest.py` to simulate:
- Database sessions
- Proxmox API responses
- Cluster configurations
- Deployment progress tracking

## Phase 1: Test the Wizard

The wizard script (`wizard/setup-wizard.sh`) creates the management VM on Proxmox. Test it both interactively and in non-interactive mode.

### Interactive Mode

Run directly on the Proxmox host:

```bash
cd /path/to/Twinbox
bash wizard/setup-wizard.sh
```

Answer the prompts (cluster name, resources, node selection, etc.).

**Expected outcome**: Management VM created with cloud-init ISO injected.

### Non-Interactive Mode

For automated testing or CI:

```bash
export CLUSTER_NAME="testcluster"
export CPU_CORES=2
export RAM_GB=4
export DISK_GB=32
export BRIDGE="vmbr0"
export SELECTED_NODE="pve1"
bash wizard/setup-wizard.sh
```

### Wizard Verification

After wizard completes, verify:

1. **VM exists and is running**:
   ```bash
   qm list | grep twinbox-mgmt-${CLUSTER_NAME}
   qm status <vmid>
   ```

2. **Cloud-init ISO attached**:
   ```bash
   qm config <vmid> | grep -E "(ide2|cloudinit)"
   ```

3. **Credentials file generated**:
   Inside the management VM (once SSHable):
   ```bash
   cat /opt/twinbox/config/proxmox-creds.yaml
   ```
   Should contain API token credentials.

4. **IP assigned**: Script should output the VM IP address via QEMU guest agent.

**Note**: Cloud-init is configured to install Docker and start the manager containers automatically. The web UI will start on port 8080 once cloud-init completes (typically 2-5 minutes).

## Phase 2: Access the Web UI (Manual Verification)

1. **SSH to Management VM** (optional, for monitoring):
   ```bash
   ssh ubuntu@<mgmt-vm-ip>
   ```

2. **Check Docker containers**:
   ```bash
   docker-compose ps
   ```
   Should show `web` and `worker` containers running (along with postgres and redis).

3. **Open browser** to `http://<management-vm-ip>:8080`

4. **Initial page** should show:
   - Cluster name (from wizard)
   - Status: Proxmox Connected ✓ (after credentials auto-loaded)
   - Button: "Deploy Complete Cluster"

5. **Click "Deploy Complete Cluster"**

6. **Review page**:
   - Shows detected Proxmox cluster topology (nodes, resources)
   - Displays auto-generated VM placement plan
   - Shows network configuration (bridge, DHCP mode)
   - You can modify counts or resources if needed
   - Click "Start Deployment"

7. **Deployment page**:
   - Live progress with step indicators
   - Terminal-style log window streaming real-time output
   - Can cancel at any time

8. **Wait 5-15 minutes** depending on resources and cluster size.

9. **Completion page**:
   - Success message
   - Kubernetes version, node count
   - Traefik ingress IP (from MetalLB)
   - **Download kubeconfig** button (save this file)

## Phase 3: Verify the Cluster

1. **Copy the kubeconfig** to your local machine.

2. **Test with kubectl**:
   ```bash
   export KUBECONFIG=/path/to/downloaded/kubeconfig
   kubectl get nodes
   ```
   Expected: All nodes (control-plane and workers) in `Ready` state.

3. **Test Traefik ingress**:
   ```bash
   kubectl create deployment nginx --image=nginx
   kubectl expose deployment nginx --port=80 --type=LoadBalancer
   kubectl get svc nginx
   ```
   Wait for EXTERNAL-IP (from MetalLB pool). Then `curl http://<external-ip>` should return nginx page.

## Cleanup

If you want to delete the cluster and start over:

**Manual cleanup** (through Proxmox UI or CLI):
- Delete all VMs: Management VM, Talos control plane VMs, worker VMs
- Delete resource pool: `pvesh delete /pools/twinbox-<cluster-name>`
- Delete user: `pvesh delete /access/users/twinbox@pve`

**Note**: The web UI does not yet implement cluster deletion. This is a future enhancement.

## Troubleshooting

### Wizard Issues

**Error: "This script must run on a Proxmox VE host"**
- Make sure you're running on the Proxmox console (not a client machine)
- Check that `/etc/pve` directory exists

**Error: "qm command not found"**
- Proxmox VE not installed correctly; reinstall or use proper node

**VM creation fails**
- Check storage availability: `pvesh get /storage`
- Verify network bridge exists: `ip link show vmbr0`
- Ensure you have enough free resources (CPU, RAM, disk)
- Verify cloud-localds is installed: `which cloud-localds`

**Cloud-init ISO creation fails**
- Ensure `cloud-localds` is available on Proxmox host
- Check there's enough temporary disk space in `/tmp`
- Verify the Ubuntu cloud image exists or can be downloaded

**IP assignment fails**
- The script waits for the QEMU guest agent to report the IP
- Ensure the VM actually boots and cloud-init runs successfully
- Check VM console in Proxmox UI for boot errors
- Manually check: `qm guest cmd <vmid> "network-get-interfaces"`

### Web UI Issues

**Can't reach http://<ip>:8080**
- Wait 2-5 minutes after VM boots for cloud-init to complete
- Verify VM is running: `qm status <vmid>`
- Check if SSH works: `ssh ubuntu@<ip>`
- Check Docker containers: `ssh ubuntu@<ip> "docker-compose ps"`
- Check web container logs: `ssh ubuntu@<ip> "docker-compose logs web"`
- Verify port 8080 is exposed and not blocked by firewall

**"Database connection failed"**
- PostgreSQL container may not be ready yet; wait a bit longer
- Check all containers are running: `docker-compose ps`
- Check PostgreSQL logs: `docker-compose logs postgres`
- Verify DATABASE_URL environment variable in `.env` file

**"Redis connection failed"**
- Redis container may not be ready; check status
- Background jobs won't work until Redis is up, but UI should still function
- Check Redis logs: `docker-compose logs redis`

**Deployment fails at "Create Talos VMs"**
- Check Proxmox credentials in `/opt/twinbox/config/proxmox-creds.yaml` inside Management VM
- Verify you have enough free resources on Proxmox nodes for the planned VMs
- Check Proxmox API token has proper permissions (full access to VMs)
- Check worker logs for specific error: `docker-compose logs worker`
- Ensure Talos ISO is accessible in the VM (mounted at `/tmp/talos`)

**Talos config application fails**
- Ensure Talos nodes can reach the Management VM on the network
- Verify time synchronization across nodes (check with `timedatectl`)
- Confirm Talos ISO is mounted and accessible
- Check worker logs for talosctl errors

**Kubernetes bootstrap fails**
- Check control plane nodes are accessible: try `talosctl` commands from management VM
- Common issue: insufficient resources; Talos needs at least 2 CPUs, 4GB RAM per node
- Verify node health: `talosctl health --nodes <cp-ip>`
- Check for network/firewall issues blocking communication

**CNI/MetalLB/Traefik installation fails**
- Verify kubectl can connect and has admin context: `kubectl get nodes`
- Check Pod network CIDR isn't overlapping with existing networks
- Review failed pod logs: `kubectl logs -n <namespace> <pod-name>`
- Check MetalLB speaker logs: `kubectl logs -n metallb-system -l app=metallb`
- Verify nodes have internet access to pull images

## Expected Behavior

- **Wizard execution**: 2-5 minutes (includes downloading cloud image if needed, creating VM, waiting for IP)
- **Cloud-init**: 2-5 minutes (installs Docker, pulls images, starts containers via docker-compose)
- **Web UI ready**: After cloud-init completes, containers start automatically; UI available at port 8080 within ~30 seconds
- **Deployment**: 5-15 minutes depending on cluster size and network speed
  - Create Talos VMs: 1-2 min
  - Wait for Talos: 2-5 min
  - Generate Talos configs: <1 min
  - Apply Talos configs: 2-5 min
  - Bootstrap Kubernetes: 2-5 min
  - Wait for workers: 1-3 min
  - Install Calico: 1-2 min
  - Install MetalLB: 1-2 min
  - Install Traefik: 1-2 min

## Success Criteria

✅ Wizard completes and management VM boots with cloud-init
✅ VM accessible via SSH (ubuntu user)
✅ `/opt/twinbox/config/proxmox-creds.yaml` exists with valid credentials
✅ Docker Compose services all running (postgres, redis, web, worker)
✅ Web UI loads at http://<mgmt-ip>:8080 and shows Proxmox connection
✅ Cluster record auto-created on first page load (no manual setup needed)
✅ Review page shows detected topology and placement plan
✅ Deployment completes without errors
✅ Kubernetes cluster ready: `kubectl get nodes` shows all nodes Ready
✅ LoadBalancer service gets external IP from MetalLB
✅ Can access services via Traefik ingress

## Testing the Manager Components Separately

If you want to test the manager application without running the wizard:

1. **Clone repository and set up locally**:
   ```bash
   git clone <repository>
   cd Twinbox
   python3 -m venv .venv
   source .venv/bin/activate
   pip install -r requirements-test.txt
   ```

2. **Prepare environment**:
   ```bash
   cd manager
   cp .env.example .env
   # Edit .env to point to your Proxmox cluster and set database URL
   ```

3. **Create credentials file** (if not using wizard):
   ```bash
   mkdir -p /opt/twinbox/config
   cat > /opt/twinbox/config/proxmox-creds.yaml <<EOF
   proxmox:
     host: "your-proxmox-host"
     token_id: "your-token-id"
     token_secret: "your-token-secret"
     verify_ssl: false
   EOF
   ```

4. **Run database migrations**:
   ```bash
   alembic upgrade head
   ```

5. **Start services**:
   ```bash
   # Option A: uvicorn for development
   uvicorn manager.web.main:app --reload --host 0.0.0.0 --port 8000

   # Option B: Docker Compose (includes postgres and redis)
   docker-compose up -d postgres redis
   docker-compose up web
   ```

6. **Run RQ worker** (in separate terminal):
   ```bash
   rq worker twinbox-high twinbox-low twinbox-default
   ```

7. **Access web UI** at http://localhost:8000 (or configured port).

## Next Steps After Successful Test

- Push your changes to GitHub
- Create a PR for review
- Add more tests
- Enhance UI (add delete cluster, cluster dashboard)
- Add support for multi-cluster management
- Add HTTPS, authentication
- Implement rolling upgrades
- Add monitoring stack

Good luck with the test!
