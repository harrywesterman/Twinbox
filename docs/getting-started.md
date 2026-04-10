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

The wizard creates the Management VM, seeds runtime directories in `/opt/twinbox`, writes `.env`, and kicks off the Ansible-driven bootstrap.
That host-side tree is runtime state, not a full repo checkout. The management images carry the executable step catalog and manager scripts.
The Management VM now boots through a thin cloud-init layer that installs Ansible and lets the Ansible baseline install Docker, the management tools, and the runtime stack.
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
- `/opt/twinbox/bootstrap/secrets/global/velero.json`
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
Talos control planes stay at `4 GB RAM / 10 GB disk`, while worker disks scale from the Proxmox host's free space and Longhorn is scheduled onto workers through the Talos role label.

## Management VM maintenance

Management VM maintenance is now handled by Ansible during the host bootstrap. There is no separate wizard step for it anymore.

## Recovery

If the manager stack needs a restart:

```bash
ssh root@<management-vm-ip> 'docker compose pull && docker compose up -d'
```

If bootstrap files are missing, rerun the host bootstrap logic:

```bash
ssh root@<management-vm-ip> 'sudo ansible-playbook -i localhost, -c local /opt/twinbox/bootstrap/ansible/management-vm-maintenance.yml'
```

If you need to inspect a step script, do it inside the worker container:

```bash
ssh root@<management-vm-ip> 'docker exec twinbox-manager-worker sh -lc "sed -n \"1,80p\" /opt/twinbox/categories/talos-cluster/steps/install-pgadmin4/run.sh"'
```
