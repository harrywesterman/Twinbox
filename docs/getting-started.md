# Getting Started

This guide covers the current Twinbox flow.

## Prerequisites

- Proxmox host access
- Internet access from Proxmox and the future Management VM
- Enough CPU, RAM, and storage for one Management VM and later Talos nodes

## Step 1: Run the Proxmox wizard

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/harrywesterman/twinbox/main/wizard/setup-wizard.sh)
```

The wizard creates the Management VM, installs Docker CE, clones Twinbox into `/opt/twinbox`, writes `.env`, and starts the manager stack.

## Step 2: Verify bootstrap material on the Management VM

```bash
ssh root@<management-vm-ip> 'find /opt/twinbox/bootstrap -maxdepth 3 -type f | sort'
```

Expected early files:

- `/opt/twinbox/bootstrap/secrets/global/proxmox.json`
- `/opt/twinbox/bootstrap/secrets/global/traefik-dashboard.json`
- `/opt/twinbox/bootstrap/openbao/seal/current.key`
- `/opt/twinbox/bootstrap/openbao/seal/current-key-id`

## Step 3: Open the wizard UI

- `http://<management-vm-ip>:3000`

Use the UI to:

1. Deploy the Talos cluster
2. Install Flannel
3. Install Argo CD
4. Install Longhorn
5. Install OpenBao and sync bootstrap secrets
6. Install Traefik and continue through the GitOps application steps

## Recovery

If the manager stack needs a restart:

```bash
ssh root@<management-vm-ip> 'cd /opt/twinbox && docker compose pull && docker compose up -d'
```

If bootstrap files are missing, rerun the host bootstrap logic:

```bash
ssh root@<management-vm-ip> 'cd /opt/twinbox && sudo bash scripts/bootstrap-vm.sh'
```
