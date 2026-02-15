# Twinbox Quick Deploy Guide

**Simplified Kubernetes on Proxmox - Two-Phase Setup**

---

## TL;DR

```bash
# Phase 1: On your Proxmox console (as root):
curl -sSL https://raw.githubusercontent.com/harrywesterman/Twinbox/main/wizard/setup-wizard.sh | bash

# Phase 2: SSH to the Management VM and start the stack:
ssh ubuntu@<management-vm-ip>
cd /opt/twinbox/manager && docker-compose up -d

# Phase 3: Open browser to http://<management-vm-ip>:8080 and deploy cluster
```

---

## What Gets Deployed

**Phase 1 (Wizard) creates:**
- **1 Management VM** (Ubuntu 22.04 Cloud) with:
  - Docker installed and configured
  - Git repository cloned to `/opt/twinbox`
  - SSH access enabled for `ubuntu` user
  - Docker Compose stack ready to start (but NOT auto-started)

**Phase 2 (Manual) starts:**
- PostgreSQL database
- Redis queue
- FastAPI web service
- RQ worker

**Phase 3 (Web UI) deploys:**
- **N Talos control plane VMs** (immutable Kubernetes OS)
- **M Talos worker VMs**
- **Kubernetes cluster** with:
  - Calico CNI (pod networking)
  - MetalLB (load balancing)
  - Traefik (ingress controller)

---

## Detailed Steps

### Phase 1: Bootstrap (Run on Proxmox)

**Option A: Direct download (simplest)**

```bash
curl -sSL https://raw.githubusercontent.com/harrywesterman/Twinbox/main/wizard/setup-wizard.sh | bash
```

**Option B: Download first, inspect, then run**

```bash
curl -sSL https://raw.githubusercontent.com/harrywesterman/Twinbox/main/wizard/setup-wizard.sh -o /tmp/setup-wizard.sh
chmod +x /tmp/setup-wizard.sh
bash /tmp/setup-wizard.sh
```

The wizard will:
1. Verify you're on Proxmox
2. Ask for cluster name (e.g., "production")
3. Ask for Management VM size (CPU/RAM/disk, defaults are fine)
4. Ask for network bridge (default `vmbr0`)
5. Create `twinbox@pve` user with limited permissions
6. Create resource pool `twinbox-<cluster-name>`
7. Generate Proxmox API token
8. Create Management VM with minimal Ubuntu Cloud Image
9. Start VM and wait for IP

**Output includes:**
```
==========================================
 Twinbox Setup Complete!
==========================================

Management VM ready!

  VM ID: 100
  Name: twinbox-mgmt-production
  IP: 192.168.1.150

NEXT STEPS:
1. SSH to the VM: ssh ubuntu@192.168.1.150
2. Start the stack: cd /opt/twinbox/manager && docker-compose up -d
3. Open browser to: http://192.168.1.150:8080
```

### Phase 2: Manual Startup (After Wizard Completes)

After the wizard finishes and prints the VM IP:

**Step 1: SSH to the Management VM**

```bash
ssh ubuntu@192.168.1.150
```

**Step 2: Start the Docker Compose stack**

```bash
cd /opt/twinbox/manager
docker-compose up -d
```

**Step 3: Verify containers are running**

```bash
docker-compose ps
```

Expected output:
```
   Name                 Command               State                Ports
-----------------------------------------------------------------------------------------
postgres   docker-entrypoint.sh postgres   Up (healthy)   0.0.0.0:5432->5432/tcp
redis      docker-entrypoint.sh redis ...   Up (healthy)   0.0.0.0:6379->6379/tcp
web        uvicorn manager.web.main: ...   Up (healthy)   0.0.0.0:8000->8000/tcp
worker     rq worker twinbox-high ...      Up (healthy)   ...
```

**Step 4: Check logs if needed**

```bash
# View web service logs
docker-compose logs -f web

# View worker logs
docker-compose logs -f worker

# Check all logs
docker-compose logs -f
```

### Phase 3: Open Web UI

After containers are running, open `http://<management-vm-ip>:8080` in your browser.

You should see:
- Cluster name displayed
- Proxmox status: Connected ✓
- Button: "Deploy Complete Cluster"

### Phase 4: Deploy the Cluster

1. Click **"Deploy Complete Cluster"**

2. **Review page**:
   - See auto-detected Proxmox cluster topology
   - View VM placement plan (which VM on which host)
   - Check network settings (bridge, DHCP)
   - Optionally modify counts or resources
   - Click **"Start Deployment"**

3. **Deployment page**:
   - Watch live logs as each step executes
   - Progress bar shows completion percentage
   - Estimated time remaining updates

4. Wait for completion (5-15 minutes).

5. **Complete page**:
   - Success message: "🎉 Cluster Ready!"
   - Download **kubeconfig** (IMPORTANT: save this file)
   - Note Traefik ingress IP

### Step 5: Use Your Cluster

```bash
# Set kubeconfig
export KUBECONFIG=/path/to/downloaded/kubeconfig

# Check nodes
kubectl get nodes

# Deploy an app
kubectl create deployment nginx --image=nginx
kubectl expose deployment nginx --port=80 --type=LoadBalancer

# Get external IP
kubectl get svc nginx
# Wait for EXTERNAL-IP to be assigned (e.g., 192.168.1.201)

# Access via browser: http://192.168.1.201
```

---

## Architecture Overview

```
┌─────────────────┐
│   Proxmox VE    │
│   (Physical)    │
├─────────────────┤
│  twinbox@pve    │  ← Created by bootstrap
│  Resource Pool  │  ← twinbox-production
│  VMs:           │
│  - Management   │
│  - Talos CPs    │  ← Created by deployment
│  - Talos Workers│
└─────────────────┘
          │
          │
┌─────────────────┐
│ Management VM   │  Ubuntu 22.04 Cloud
│  (Docker)       │
├─────────────────┤
│  PostgreSQL     │  ← Cluster state, credentials
│  Redis          │  ← Job queue
│  FastAPI        │  ← Web UI (port 8080)
│  RQ Worker      │  ← Executes deployment tasks
└─────────────────┘
          │
          │ talosctl, kubectl
          │
┌─────────────────┐
│  Talos VMs      │  Immutable Kubernetes nodes
│  (CP + Workers) │
├─────────────────┤
│  Kubernetes     │  Production-ready cluster
│  Calico CNI     │
│  MetalLB        │
│  Traefik        │
└─────────────────┘
```

---

## Customization

After deployment, you can:

- **Resize cluster**: Add more worker nodes (not yet in UI, but possible via database)
- **Change network**: Modify MetalLB IP pool, Traefik configuration
- **Install add-ons**: Monitoring (Prometheus), logging (Loki), service mesh (Istio)
- **Enable HTTPS**: Configure Traefik with Let's Encrypt
- **Multi-cluster**: Run multiple Twinbox Management VMs, each managing separate clusters

---

## Troubleshooting

See [TESTING.md](TESTING.md) for comprehensive troubleshooting guide.

### Common Issues

**Web UI not accessible after wizard:**

- Have you started the Docker stack? SSH to the VM and run: `cd /opt/twinbox/manager && docker-compose up -d`
- Check container status: `docker-compose ps`
- All containers must be "Up" (healthy). If not, check logs: `docker-compose logs`
- Verify port 8080 is exposed and not blocked by firewall

**Docker containers fail to start:**

- Check Docker is installed: `docker --version`
- Check Docker service: `sudo systemctl status docker`
- Check disk space: `df -h` (need ~2GB free)
- Check container logs: `docker-compose logs <service-name>`

**Web UI loads but shows "Proxmox Disconnected":**

- Check web container logs: `docker-compose logs web`
- Verify credentials file exists: `ls /opt/twinbox/config/proxmox-creds.yaml`
- Check file permissions: `sudo cat /opt/twinbox/config/proxmox-creds.yaml` (should be readable by ubuntu user)
- Validate Proxmox API token has correct permissions (VM Admin, Sys Admin)

**Deployment fails:**

- Check worker logs: `docker-compose logs worker`
- Check Proxmox API token permissions, available resources (CPU, RAM, disk)
- Ensure resource pool exists: `pvesh get /pools` (should show `twinbox-<cluster-name>`)
- Verify VM ID range doesn't conflict with existing VMs

**Cannot SSH to Management VM:**

- Verify VM is running in Proxmox: `qm status <vmid>`
- Check VM IP in Proxmox console
- Verify network bridge configuration is correct
- Check VM console output via Proxmox UI for boot errors

**Post-deployment: Nodes not Ready:**

- Check Talos logs: `talosctl logs --nodes <node-ip>`
- Verify Talos VMs have proper network access
- Check MetalLB IP pool doesn't conflict with existing network

---

## Cleaning Up

```bash
# Delete all VMs created by Twinbox (from Proxmox):
qm stop <vmid1> <vmid2> ...
qm destroy <vmid1> <vmid2> ...

# Remove resource pool
pvesh delete /pools/twinbox-<cluster-name>

# Remove twinbox user
pvesh delete /access/users/twinbox@pve
```

---

## License

MIT
