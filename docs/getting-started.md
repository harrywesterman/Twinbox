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
The generated VM and the later Talos cluster both use the same `TWINBOX_TIME_SERVER` value for NTP.
The wizard also stores the cluster login password in `/opt/twinbox/bootstrap/secrets/global/twinbox-login.json` so later Authentik onboarding can reuse it.

## Step 2: Verify bootstrap material on the Management VM

```bash
ssh root@<management-vm-ip> 'find /opt/twinbox/bootstrap -maxdepth 3 -type f | sort'
```

Expected early files:

- `/opt/twinbox/bootstrap/secrets/global/proxmox.json`
- `/opt/twinbox/bootstrap/secrets/global/traefik-dashboard.json`
- `/opt/twinbox/bootstrap/secrets/global/twinbox-login.json`
- `/opt/twinbox/bootstrap/openbao/seal/current.key`
- `/opt/twinbox/bootstrap/openbao/seal/current-key-id`

## Step 3: Open the wizard UI

- `http://<management-vm-ip>:3000`

Use the UI to:

1. Deploy the Talos cluster
2. Install Argo CD
3. Install Longhorn and make it the default storage class
4. Install OpenBao and sync bootstrap secrets
5. Install CloudNativePG
6. Install Postgres clusters
7. Install Traefik
8. Install Authentik
9. Create the first Authentik user and `admins` group
10. Install Velero backup
11. Install pgAdmin 4
12. Continue through the GitOps application steps

Cilium is installed during the Talos provisioning step, so there is no separate networking step in the wizard.

## Management VM maintenance

Use the `Configure Management VM maintenance` step in the UI to keep Ubuntu patched and baseline hardening applied without touching `/opt/twinbox`.

The step installs a daily host cron entry that runs the local maintenance playbook on the Management VM. Password authentication stays enabled.

If you prefer a manual host-side setup, you can still run:

```bash
ssh root@<management-vm-ip> 'cd /opt/twinbox && sudo bash scripts/install-management-vm-maintenance.sh'
```

## Recovery

If the manager stack needs a restart:

```bash
ssh root@<management-vm-ip> 'cd /opt/twinbox && docker compose pull && docker compose up -d'
```

If bootstrap files are missing, rerun the host bootstrap logic:

```bash
ssh root@<management-vm-ip> 'cd /opt/twinbox && sudo bash scripts/bootstrap-vm.sh'
```
