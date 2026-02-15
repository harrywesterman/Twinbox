# Twinbox Quick Deploy Guide

**Simplified Kubernetes on Proxmox - One Command to Cloud**

---

## TL;DR

```bash
# 1. On your Proxmox console (as root):
curl -sSL https://raw.githubusercontent.com/harrywesterman/Twinbox/main/wizard/setup-wizard.sh | bash

# 2. Wait 2-3 minutes, then open browser to http://<management-vm-ip>:8080

# 3. Click "Deploy Complete Cluster" → Review → Start Deployment

# 4. Wait 5-15 minutes. Download kubeconfig. Done.
```

---

## What Gets Deployed

- **1 Management VM** (Ubuntu 22.04 Cloud) running:
  - PostgreSQL database
  - Redis queue
  - FastAPI web service
  - RQ worker
- **N Talos control plane VMs** (immutable Kubernetes OS)
- **M Talos worker VMs**
- **Kubernetes cluster** with:
  - Calico CNI (pod networking)
  - MetalLB (load balancing)
  - Traefik (ingress controller)

All automatically provisioned and configured.

---

## Detailed Steps

### Step 1: Bootstrap (Run on Proxmox)

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

The script will:
1. Verify you're on Proxmox
2. Ask for cluster name (e.g., "production")
3. Ask for Management VM size (CPU/RAM/disk, defaults are fine)
4. Ask for network bridge (default `vmbr0`)
5. Create `twinbox@pve` user with limited permissions
6. Create resource pool `twinbox-<cluster-name>`
7. Generate Proxmox API token
8. Create Management VM with Ubuntu Cloud Image
9. Start VM and wait for IP

### Step 2: Wait for Cloud-Init

After the script prints the VM IP:

```
==========================================
 Twinbox Setup Complete!
==========================================

Management VM ready!

  VM ID: 100
  Name: twinbox-mgmt-production
  IP: 192.168.1.150

1. Wait 1-2 minutes for cloud-init to finish
2. Open browser to: http://192.168.1.150:8080
```

**Important**: Cloud-init installs Docker, downloads Twinbox repo, builds images, and starts containers. This takes 2-5 minutes. You can monitor progress:

```bash
# SSH to the Management VM (if you want to watch):
ssh ubuntu@192.168.1.150

# Check cloud-init status:
sudo cloud-init status --wait

# Check Docker containers:
docker-compose ps

# View logs:
docker-compose logs -f web
```

### Step 3: Open Web UI

Open `http://<management-vm-ip>:8080` in your browser.

You should see:
- Cluster name displayed
- Proxmox status: Connected ✓
- Button: "Deploy Complete Cluster"

### Step 4: Deploy the Cluster

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

Common issues:

- **Web UI not loading**: Cloud-init still running; check `docker-compose ps` on Management VM
- **Deployment fails**: Check Proxmox API token permissions, available resources
- **Nodes not Ready**: Check Talos logs via `talosctl` or VM console

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
