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
That host-side tree is runtime state, not a full repo checkout. The management images carry the executable step catalog and manager scripts, so the code you change must be committed, pushed to `main`, rebuilt by GitHub Actions, and then pulled on the VM.
The Management VM now boots through a thin cloud-init layer that installs Ansible and lets the Ansible baseline install Docker, the management tools, and the runtime stack.
The generated VM and the later Talos cluster both use the same `TWINBOX_TIME_SERVER` value for NTP.
The wizard also stores the cluster login password in `/opt/twinbox/bootstrap/secrets/global/twinbox-login.json` so later Authentik onboarding can reuse it.

## Step 2: Verify bootstrap material on the Management VM

Connect as the `twinbox` user (the wizard creates this account):

```bash
ssh twinbox@<management-vm-ip> 'find /opt/twinbox/bootstrap -maxdepth 3 -type f | sort'
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

Use the UI to work through the setup steps. The exact order depends on your chosen ingress route, but the core platform steps are:

### Core Infrastructure

1. **Deploy Talos Cluster** (`provision-nodes`) — Creates VMs, bootstraps Talos, installs Cilium (kube-proxy-free with Hubble)
2. **Install Argo CD** (`install-argocd`) — GitOps controller
3. **Install Longhorn** (`install-longhorn-storage`) — Default storage class, SeaweedFS backup target
4. **Install Prometheus** (`install-prometheus`) — Metrics and alerting stack
5. **Install Loki** (`install-loki`) — Log aggregation
6. **Install Tempo** (`install-tempo`) — Distributed tracing
7. **Install Alloy** (`install-alloy`) — Unified telemetry collector
8. **Install Grafana** (`install-grafana`) — Dashboards with pre-seeded Twinbox views

### Secrets & Identity

9. **Install Secret Sync** (`install-secret-sync`) — External Secrets Operator + OpenBao
10. **Install CloudNativePG** (`install-cloudnativepg`) — PostgreSQL operator
11. **Install Postgres Clusters** (`install-postgres-clusters`) — Authentik database
12. **Install Authentik IDP** (`install-authentik-idp`) — Identity provider with OIDC
13. **Create Users and Groups** (`create-users-and-groups`) — First user + `admins` group

### Ingress & Networking

14. **Choose Ingress Route** (`choose-ingress-route`) — Select and configure your ingress strategy
15. **Configure Cloudflare Tunnel** (`configure-cloudflare-tunnel`) — Outbound tunnel *(if Cloudflare Tunnel selected, prd-only)*
16. **Deploy NetBird Bastion** (`provision-netbird-bastion`) — Hetzner or existing Debian/Ubuntu VM *(if NetBird selected)*
17. **Configure NetBird Ingress** (`configure-netbird-ingress`) — SSO, groups, setup keys *(if NetBird selected)*
23. **Install NetBird Routing Peers** (`install-netbird-routing-peers`) — K8s DaemonSet *(if NetBird selected)*
24. **Configure NetBird Admin Access** (`configure-netbird-admin-access`) — Management VM enrollment *(if NetBird selected)*

### Platform Services

25. **Install Traefik** (`install-traefik`) — Ingress controller
26. **Install Velero Backup** (`install-velero-backup`) — Cluster backups to SeaweedFS
27. **Install Velero UI** (`install-velero-ui`) — Backup dashboard with OIDC
28. **Install Management Backup** (`install-management-backup`) — Host cron jobs for etcd + restic
29. **Install CrowdSec** (`install-crowdsec`) — IDS + Traefik bouncer
30. **Install ntfy** (`install-ntfy`) — Push notifications for alerts
31. **Install Browser SSH** (`install-browser-ssh`) — Termix browser shell to the Management VM and bastion, plus the opkssh Authentik app
32. **Install opkssh** (`install-opkssh`) — Authentik + MFA SSH certificates for the Management VM and bastion

### User-Facing Services

32. **Install Headlamp** (`install-headlamp`) — Kubernetes dashboard with OIDC
33. **Install Twinbox Portal** (`install-twinbox-portal`) — User app launcher
34. **Install Dashy Dashboard** (`install-dashy-dashboard`) — Legacy admin launcher
35. **Install Management Consoles** (`install-management-consoles`) — Proxmox, Longhorn, Forgejo, SeaweedFS UIs
36. **Install pgAdmin 4** (`install-pgadmin4`) — PostgreSQL management
37. **Configure Argo CD OIDC** (`configure-argocd-oidc`) — Argo CD Authentik integration

### Application Bundles (optional)

38. **Twinbox Desktop** — OpenCloud, Outline, HedgeDoc, Zulip, Jitsi, Paperless, Immich, SearXNG, Audiobookshelf, Pixelfed, Stirling PDF, Karakeep, Mailu, Mastodon, Matrix, Nextcloud
39. **Mijn Bureau** — Nextcloud, Outline, Jitsi
40. **La Suite** — Outline, Nextcloud, Zulip, Jitsi
41. **openDesk** — OpenCloud, Nextcloud, Zulip, Jitsi

### Individual Apps (optional)

Any of the 20+ individual apps: Audiobookshelf, FreshRSS, HedgeDoc, Immich, Jitsi, Karakeep, n8n, Nextcloud, OpenCloud, OpenWebUI, Outline, Paperless, Pixelfed, SearXNG, Stirling PDF, Vaultwarden, Zulip.

Cilium is installed during the Talos provisioning step, so there is no separate networking step in the wizard.
Talos control planes stay at `4 GB RAM / 10 GB disk`, while worker disks default to `100%` of the free space shared across the three Proxmox hosts and can be tuned with the worker-disk slider; Longhorn is scheduled onto workers through the Talos role label.

## Management VM maintenance

Management VM maintenance is handled by Ansible during the host bootstrap. There is no separate wizard step for it anymore.

If bootstrap files are missing, rerun the host bootstrap logic:

```bash
ssh twinbox@<management-vm-ip> 'sudo ansible-playbook -i localhost, -c local /opt/twinbox/bootstrap/ansible/management-vm-maintenance.yml'
```

## Recovery

If the manager stack needs a restart, run this from the Management VM (`.env` is root-owned, so use `sudo`):

```bash
ssh twinbox@<management-vm-ip>
sudo -n sh -lc 'cd /opt/twinbox && docker compose pull && docker compose up -d'
```

Use this after the `Publish Docker Images` workflow finishes for the commit you want to run.

If you need to inspect a step script, do it inside the worker container:

```bash
ssh twinbox@<management-vm-ip> 'docker exec twinbox-manager-worker sh -lc "sed -n \"1,80p\" /opt/twinbox/categories/talos-cluster/steps/install-pgadmin4/run.sh"'
```
