# Setup Wizard

`wizard/setup-wizard.sh` runs directly on a Proxmox host and bootstraps the Twinbox Management Environment.

## What It Does

1. Detects existing Twinbox clusters on the host via VM tags, snippets, Proxmox users, and roles.
2. Presents a menu to create a new cluster or manage (remove) an existing one.
3. Auto-detects network settings (host IP, gateway, DNS, bridge, next free VMID).
4. Creates an Ubuntu 24.04 Management VM with cloud-init plus an Ansible baseline (runtime directories, `.env`, Docker CE, management tools, `docker compose`).
5. Creates a cluster-specific Proxmox API user and least-privilege role.
6. Waits for the Management VM to boot and the Twinbox web interface to become available.

## Run

From Proxmox:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/harrywesterman/twinbox/main/wizard/setup-wizard.sh)
```

From a local clone:

```bash
bash wizard/setup-wizard.sh
```

For fast iteration without pushing:

```bash
cp .env.wizard.local.example .env.wizard.local
# set WIZARD_DEV_SSH_TARGET=root@<proxmox-host>
make wizard-dev-run
```

## Prompts

- **Cluster action**: create new or remove existing
- **Cluster name**: preset (`prd`, `dev`, `tst`) or custom (1-3 lowercase letters); `prd` is preselected by default
- **SSH public key**: auto-detected from `/root/.ssh/` or entered manually
- **Cluster login password**: min 8 chars, upper + lower + special
- **VM settings**: name, IP, netmask, DNS, disk size, memory (editable form)
- **VMID/IP allocation**: auto-suggested, editable before proceeding

## After Completion

Open the Twinbox web interface at the URL shown in the wizard:

- UI: `http://<management-vm-ip>:3000`
- API: `http://<management-vm-ip>:8080/api/health`

Talos provisioning and cluster configuration continue from the web UI.

## Validation

On the Management VM:

```bash
docker --version
docker compose version
curl -fsS http://localhost:8080/api/health
```

## Recovery

```bash
cd /opt/twinbox
# adjust .env if required
docker compose pull
docker compose up -d
```

## Notes

- The VM baseline is installed through Ansible after cloud-init seeds the bootstrap tree.
- The wizard keeps passwords out of the completion screen.
- VM cleanup on failure is automatic (stops and destroys the VM if the script exits before completion).
- The wizard loops back to the main menu after each action, allowing multiple cluster operations in one session.
