# Wizard Guide

`wizard/setup-wizard.sh` runs on Proxmox and prepares a Management VM for a selected cluster.

## What It Does

- Prompts for one Management VM form with name, IP, netmask, DNS, disk size, and memory.
- Prompts for cluster name (`ontwikkel`, `test`, `productie`, or custom).
- Uses the cluster slug in VM name, Proxmox API user/role, and tags.
- Lets users load saved answers again on the question pages instead of only on the first screen.
- Detects existing resources for the same cluster through Proxmox cluster inventory and supports cleanup with explicit confirmation.
- Cleanup is cluster-wide and node-aware, so clusters with VMs spread across multiple Proxmox hosts can still be removed safely.
- Creates the Management VM from Ubuntu 24.04 cloud image.
- Seeds a thin cloud-init that installs Ansible and hands the Management VM baseline to an Ansible playbook.
- Creates the `/opt/twinbox` runtime tree without cloning the Twinbox repository onto the VM.
- Starts the manager stack with `docker compose pull && docker compose up -d` after the Ansible baseline has installed Docker and the management tools.
- Management VM maintenance is now handled by Ansible and no longer appears as a user-facing wizard step.

## Run

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/harrywesterman/twinbox/main/wizard/setup-wizard.sh)
```

For local development of the wizard itself:

```bash
cp .env.wizard.local.example .env.wizard.local
# set WIZARD_DEV_SSH_TARGET=root@<proxmox-host>
make wizard-dev-run
```

The dev runner uploads only the current local `wizard/setup-wizard.sh` to the Proxmox host and starts that copy over SSH with an interactive TTY. It does not sync other unpushed repository changes into the eventual Management VM clone.

## Validate Management VM

```bash
ssh ubuntu@<management-vm-ip>
docker --version
docker compose version
ansible-playbook --version
curl -fsS http://localhost:8080/api/health
```

## Notes

- Twinbox compose uses prebuilt public GHCR images.
- The host baseline is now managed through Ansible, not by a repository checkout on the VM.
- Keep deployment in trusted LAN scope for phase 1.
- The wizard writes a cloud-init snippet under `/var/lib/vz/snippets/` with mode `0600`.
- Talos VM provisioning remains in the management stack/UI and is not created directly by the wizard.
