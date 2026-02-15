# Twinbox Testing Guide

This guide walks through testing Twinbox on a real Proxmox VE cluster.

## Prerequisites

- **Proxmox VE 7.0+** with at least 16GB RAM, 4 CPU cores, and 200GB storage
- **Root access** to Proxmox console (SSH or Web Shell)
- **Internet access** from Proxmox host (to download Ubuntu ISO and Docker images)
- **Bridge network** configured (default `vmbr0`)

## Phase 1: Run the Bootstrap Script

1. **Run the wizard directly from GitHub** (no git required):
```bash
curl -sSL https://raw.githubusercontent.com/harrywesterman/Twinbox/main/wizard/setup-wizard.sh | bash
```

Or download first, inspect, then run:
```bash
curl -sSL https://raw.githubusercontent.com/harrywesterman/Twinbox/main/wizard/setup-wizard.sh -o /tmp/setup-wizard.sh
chmod +x /tmp/setup-wizard.sh
bash /tmp/setup-wizard.sh
```

3. **Answer the prompts**:
   - Cluster name: e.g., `production` (no spaces, alphanumeric)
   - Management VM CPU: default 2
   - Management VM RAM (GB): default 4
   - Management VM disk (GB): default 32
   - Network bridge: default `vmbr0` (or your preferred bridge)
   - Proxmox node: select from list (if multiple nodes)

4. **What happens**:
   - Creates `twinbox@pve` user with random password
   - Creates resource pool `twinbox-<cluster-name>`
   - Downloads Ubuntu 22.04 Cloud Image (if not already present)
   - Creates Management VM (`twinbox-mgmt-<cluster-name>`)
   - Generates API token and injects into cloud-init
   - Starts VM

5. **Wait for IP**: Script will display the VM IP address (via QEMU guest agent).

**Output example**:
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
3. You'll see the Twinbox web interface
```

## Phase 2: Access the Web UI

1. **Open browser** to `http://<management-vm-ip>:8080`

2. **Initial page** should show:
   - Cluster name: `production` (or your chosen name)
   - Status: Proxmox Connected ✓
   - Button: "Deploy Complete Cluster"

3. **Click "Deploy Complete Cluster"**

4. **Review page**:
   - Shows detected Proxmox cluster topology (nodes, resources)
   - Displays auto-generated VM placement plan
   - Shows network configuration (bridge, DHCP mode)
   - You can modify counts or resources if needed
   - Click "Start Deployment"

5. **Deployment page**:
   - Live progress with step indicators
   - Terminal-style log window streaming real-time output
   - Estimated time remaining
   - Can cancel at any time

6. **Wait 5-15 minutes** depending on resources and cluster size.

7. **Completion page**:
   - Success message: "🎉 Cluster Ready!"
   - Kubernetes version, node count
   - Traefik ingress IP (e.g., `192.168.1.200`)
   - **Download kubeconfig** button (IMPORTANT: save this file)
   - Next steps

## Phase 3: Verify the Cluster

1. **Copy the kubeconfig** to your local machine (or use the Management VM).

2. **Test with kubectl**:
```bash
export KUBECONFIG=/path/to/downloaded/kubeconfig
kubectl get nodes
```
Expected output:
```
NAME              STATUS   ROLES           AGE   VERSION
talos-cp-1        Ready    control-plane   5m    v1.28.0
talos-cp-2        Ready    control-plane   5m    v1.28.0
talos-cp-3        Ready    control-plane   5m    v1.28.0
talos-worker-1    Ready    worker          4m    v1.28.0
...
```

3. **Test Traefik ingress**:
```bash
kubectl create deployment nginx --image=nginx
kubectl expose deployment nginx --port=80 --type=LoadBalancer
kubectl get svc nginx
```
Wait for EXTERNAL-IP to be assigned (should be from MetalLB pool, e.g., `192.168.1.201`).

Then open `http://<external-ip>` in browser - you should see the nginx welcome page.

## Phase 4: Cleanup (Optional)

If you want to delete the cluster and start over:

**Option A: Through Proxmox UI/CLI**
- Delete all VMs: Management VM, Talos control plane VMs, worker VMs
- Delete resource pool: `pvesh delete /pools/twinbox-<cluster-name>`
- Delete user: `pvesh delete /access/users/twinbox@pve`

**Option B: Future Enhancement**
- Add a "Delete Cluster" button in the web UI (not implemented yet)

## Troubleshooting

### Bootstrap Script Issues

**Error: "This script must run on a Proxmox VE host"**
- Make sure you're running on the Proxmox console (not a client machine)
- Check that `/etc/pve` directory exists

**Error: "qm command not found"**
- Proxmox VE not installed correctly; reinstall or use proper node

**VM creation fails**
- Check storage availability: `pvesh get /storage`
- Verify network bridge exists: `ip link show vmbr0`
- Ensure you have enough free resources (CPU, RAM, disk)

**Cloud-init fails**
- Check VM console in Proxmox UI for errors
- Manually SSH to VM if IP assigned: `ssh ubuntu@<ip>`
- Look at cloud-init logs: `/var/log/cloud-init.log`

### Web UI Issues

**Can't reach http://<ip>:8080**
- Wait 2-3 minutes after VM boots for cloud-init to complete
- Check VM is running: `qm status <vmid>`
- Check cloud-init status: `qm guest cmd <vmid> "cloud-init status --long"`
- Check Docker containers: `ssh ubuntu@<ip> "docker-compose ps"`
- Check service logs: `ssh ubuntu@<ip> "docker-compose logs web"`

**"Database connection failed"**
- PostgreSQL container may not be ready yet; wait 30 seconds
- Check containers: `docker-compose ps`
- Check logs: `docker-compose logs postgres`

**"Redis connection failed"**
- Redis container may not be ready; wait a bit
- Background jobs won't work until Redis is up, but UI should still function

**Deployment fails at "Create Talos VMs"**
- Check Proxmox credentials are correct in `/opt/twinbox/config/proxmox-creds.yaml` inside Management VM
- Verify you have enough free resources on Proxmox nodes for the planned VMs
- Check Proxmox API token has proper permissions
- Review logs in web UI for specific error

**Talos config application fails**
- Ensure Talos nodes can reach the Management VM (network/firewall)
- Check that Talos ISO is accessible (mounted in VM)
- Verify time synchronization (Talos is picky about time)

**Kubernetes bootstrap fails**
- Check control plane nodes are Ready: `talosctl --config ./ talos-kubeconfig --nodes <ip>`
- Common issue: insufficient resources; Talos needs at least 2 CPUs, 4GB RAM per node

**CNI/MetalLB/Traefik installation fails**
- Check kubectl can connect: `kubectl get nodes`
- Verify network connectivity between nodes (Pod network CIDR not overlapping with other networks)
- Check MetalLB speaker logs: `kubectl logs -n metallb-system -l app=metallb`

## Expected Behavior

- **Bootstrap**: 2-5 minutes (downloads ISO, creates VM)
- **Cloud-init**: 2-5 minutes (installs Docker, builds images, starts containers)
- **Web UI ready**: After cloud-init completes, container startup ~30 seconds
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

✅ Management VM created and accessible via SSH
✅ Web UI loads at http://<mgmt-ip>:8080
✅ Cluster record auto-created on first page load
✅ Review page shows reasonable placement plan
✅ Deployment completes without errors
✅ `kubectl get nodes` shows all nodes Ready
✅ LoadBalancer service gets external IP from MetalLB
✅ Can access services via Traefik

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
