# Twinbox

**Production-grade Kubernetes on your own hardware. One command.**

Twinbox runs on your own hardware on the Proxmox platform and turns them into a fully configured Talos Linux cluster with GitOps, secrets, storage, backups, and ingress — all set up through a guided web interface. Then you can install your own private application set to run your own on-prem cloud.

## What you start with

Bring any machine with [Proxmox](https://www.proxmox.com/en/products/proxmox-virtual-environment/get-started) installed. Old servers, workstations, or a fresh build — anything with virtualization support works. 

The minimal hardware it runs on is:
3 x86 machines. I build this on three second hand Intel Nucs.
16 Gb of memory on each node.
500 Gb of harddisk space on each node.
1 Gbit networking, but faster is awesome.

## What Twinbox does

Run one command on the Proxmox console. The wizard creates a Management VM that boots the full Twinbox stack.

<p align="center">
  <img src="screenshots/twinbox-docs-screenshot-015.webp" alt="Proxmox setup wizard" width="800">
</p>

Open your browser to continue the installation. The web UI guides you through cluster provisioning, networking, and platform services. It takes about an hour if you have the minimal hardware! 

<p align="center">
  <img src="screenshots/twinbox-docs-screenshot-024.webp" alt="Twinbox Web wizard" width="800">
</p>

After that you have an Admin console page:

<p align="center">
  <img src="screenshots/twinbox-docs-screenshot-058.webp" alt="Web installation wizard" width="800">
</p>

## What you get

The Twinbox Portal is the portal for the users of the platform. You can install loads of applications and bundles on Twinbox that they can use.

<p align="center">
  <img src="screenshots/twinbox-docs-screenshot-056.webp" alt="Talos, Argo CD, Longhorn, OpenBao, Traefik, Velero, and more" width="800">
</p>

The Twinbox platform itself is formed of the following parts:
- **Talos Linux** — immutable, API-driven Kubernetes OS
- **Cilium** — kube-proxy-free networking and policy-ready datapath
- **Hubble** — network flow visibility and the Hubble UI dashboard
- **Argo CD** — GitOps for every component
- **Longhorn** — distributed block storage
- **Prometheus** — cluster metrics, Alertmanager, node-exporter, and kube-state-metrics
- **Grafana** — dashboarding on top of the Prometheus stack
- **Loki** — log aggregation and log querying for Grafana
- **OpenBao + External Secrets Operator** — centralized secret management
- **Traefik** — ingress and routing
- **MetalLB** — bare-metal load balancer for on-prem ingress
- **Cloudflare Tunnel** — secure external access without opening ports
- **NetBird** — self-hosted WireGuard VPN with SSO
- **Wiredoor** — WireGuard-based reverse proxy gateway
- **SeaweedFS** — S3-compatible backup target on the Management VM
- **Velero** — automated cluster backups to SeaweedFS
- **CloudNativePG** — managed PostgreSQL clusters
- **Authentik** — single sign-on and identity provider
- **CrowdSec** — collaborative intrusion detection and Traefik bouncer
- **Tempo** — distributed tracing backend for Grafana
- **Grafana Alloy** — unified telemetry collector for logs, metrics, and traces
- **Twinbox Portal** — the default user-facing launcher with settings, intranet links, and cluster status
- **Dashy** — admin launcher for operator tools on `admin.<domain>`

## App Catalog

Install additional applications through the Twinbox Portal:

- **Audiobookshelf** — audiobook and podcast server
- **FreshRSS** — self-hosted RSS feed reader
- **HedgeDoc** — real-time collaborative markdown editor
- **Immich** — photo and video backup
- **Jitsi** — video conferencing with OpenID Connect
- **Karakeep** — bookmark and web archiving
- **n8n** — workflow automation
- **Nextcloud** — file sync and collaboration
- **OpenCloud** — open source collaboration platform
- **OpenWebUI** — AI chat interface
- **Outline** — team knowledge base
- **Paperless** — document management with OCR
- **Pixelfed** — decentralized photo sharing
- **SearXNG** — privacy-respecting metasearch engine
- **Stirling PDF** — PDF manipulation tools
- **Vaultwarden** — Bitwarden-compatible password manager
- **Zulip** — threaded team chat
