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
- Downloads the runtime start script into `/opt/twinbox/scripts` and bootstraps the manager stack once from the published Docker images.
- After you change code, commit it, push it to `main`, wait for the GitHub Actions `Publish Docker Images` workflow, and then run `docker compose pull && docker compose up -d` on the VM when you want to refresh images manually.
- Management VM maintenance is now handled by Ansible and no longer appears as a user-facing wizard step.

## Run

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/harrywesterman/twinbox/main/wizard/setup-wizard.sh)
```

For running the wizard from this checkout against a Proxmox host:

```bash
cp .env.wizard.local.example .env.wizard.local
# set WIZARD_DEV_SSH_TARGET=root@<proxmox-host>
make wizard-dev-run
```

The dev runner fetches `origin/main`, uploads that `wizard/setup-wizard.sh` to the Proxmox host, and starts the uploaded copy over SSH with an interactive TTY. Before uploading, it patches the temporary copy with the matching published manager image tag. If `origin/main` has just moved and the images for that commit are still being published, the runner waits instead of starting a stale image.

To test unpushed wizard changes deliberately, run:

```bash
WIZARD_DEV_SOURCE=local make wizard-dev-run
```

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
