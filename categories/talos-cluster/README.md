# Talos Cluster Category

Core cluster provisioning and platform service configuration steps for the Twinbox web wizard.

## Overview

The `talos-cluster` category (order: 20) guides operators through the full lifecycle of creating and configuring a Talos Linux Kubernetes cluster on Proxmox. Steps range from VM provisioning to platform services, networking, security, observability, and backups.

## Structure

```
categories/talos-cluster/
├── category.yaml       # Category metadata (id: talos-cluster, title: Talos Cluster)
└── steps/              # Individual provisioning and config steps
```

## Step Groups

### Provisioning

| Step | Description |
|------|-------------|
| `provision-nodes` | Create Talos VMs on Proxmox, apply machine configs, bootstrap control plane |

### Core Platform

| Step | Description |
|------|-------------|
| `install-argocd` | Deploy Argo CD for GitOps application management |
| `install-longhorn-storage` | Deploy Longhorn distributed block storage with SeaweedFS backups |
| `install-cloudnativepg` | Deploy CloudNativePG PostgreSQL operator |
| `install-secret-sync` | Deploy External Secrets Operator and OpenBao |
| `install-authentik-idp` | Deploy Authentik identity provider and SSO |
| `create-users-and-groups` | Create the first Authentik user and `admins` group |

### Networking & Ingress

| Step | Description |
|------|-------------|
| `choose-ingress-route` | Choose the ingress branch for this cluster |
| `install-traefik` | Deploy Traefik ingress controller |
| `configure-cloudflare-dns` | Configure Cloudflare DNS records |
| `configure-cloudflare-tunnel` | Configure Cloudflare Tunnel for external access |
| `configure-metallb-ingress` | Configure MetalLB load balancer for bare-metal ingress |
| `configure-tailscale-ingress` | Configure Tailscale ingress and VPN access |
| `configure-wiredoor-ingress` | Configure Wiredoor VPN ingress |
| `configure-netbird-ingress` | Configure NetBird SSO, routing groups, and setup keys |
| `provision-netbird-bastion` | Provision the self-hosted NetBird VPS |
| `provision-wiredoor-bastion` | Provision the Wiredoor bastion host |
| `install-wiredoor-gateway` | Deploy Wiredoor gateway into Kubernetes |
| `install-netbird-routing-peers` | Deploy NetBird routing peers to Kubernetes |
| `configure-netbird-admin-access` | Enroll the Management VM as a NetBird admin peer |

### Observability

| Step | Description |
|------|-------------|
| `install-prometheus` | Deploy Prometheus, Alertmanager, node-exporter, kube-state-metrics |
| `install-loki` | Deploy Loki log aggregation for Grafana |
| `install-tempo` | Deploy Tempo trace storage and query backend |
| `install-alloy` | Deploy Grafana Alloy as shared logs/events/traces collector |
| `install-grafana` | Deploy Grafana dashboards with default datasources |
| `install-crowdsec` | Deploy CrowdSec security engine and Traefik bouncer |

### Security

| Step | Description |
|------|-------------|
| `configure-argocd-oidc` | Connect Argo CD to Authentik for OIDC login |
| `install-crowdsec` | Deploy CrowdSec security engine |

### Management & Tools

| Step | Description |
|------|-------------|
| `install-headlamp` | Deploy Headlamp Kubernetes dashboard |
| `install-pgadmin4` | Deploy pgAdmin 4 for PostgreSQL administration |
| `install-cloudtty` | Deploy browser-based Kubernetes shell |
| `install-twinbox-portal` | Deploy the Twinbox user portal |
| `install-dashy-dashboard` | Deploy Dashy legacy admin launcher |
| `install-management-consoles` | Deploy operator web consoles (SeaweedFS, etc.) |
| `install-ntfy` | Deploy ntfy push notifications |

### Backups

| Step | Description |
|------|-------------|
| `install-velero-backup` | Deploy Velero with SeaweedFS backup target |
| `install-velero-ui` | Deploy Velero UI dashboard |
| `install-management-backup` | Install Management VM cron backups |

## Step Dependencies

Steps declare `depends_on` in their `step.yaml` manifests to enforce ordering:

- `install-argocd` → `provision-nodes`
- `install-longhorn-storage` → `provision-nodes`
- `install-authentik-idp` → `install-secret-sync`
- `install-grafana` → `install-prometheus`, `install-loki`
- `install-twinbox-portal` → `install-traefik`
- `install-velero-backup` → `install-longhorn-storage`

## Runner Scripts

Each step directory contains:

- `step.yaml` — Manifest with metadata, inputs, secrets, and runner reference
- `run.sh` or `run.mjs` — The executable runner invoked by `manager-worker`
