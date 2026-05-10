# GitOps Values

Helm values overrides for Argo CD Applications in the Twinbox cluster.

## Overview

This directory contains Helm `values.yaml` files referenced by Argo CD `Application` resources via multi-source specs (`ref: values`). Each file is named after the application it configures and provides cluster-specific or opinionated defaults.

## Files

| File | App | Description |
|------|-----|-------------|
| `alloy.yaml` | Grafana Alloy | Collector configuration for logs, metrics, and traces |
| `argocd-image-updater.yaml` | Argo CD Image Updater | Automatic image update configuration |
| `cloudflare-tunnel.yaml` | Cloudflare Tunnel | Tunnel configuration and credentials |
| `cloudnativepg.yaml` | CloudNativePG | PostgreSQL operator settings |
| `crowdsec.yaml` | CrowdSec | Security engine and bouncer configuration |
| `external-secrets.yaml` | External Secrets Operator | Secret syncing from OpenBao |
| `grafana.yaml` | Grafana | Dashboard server, datasources, and authentication |
| `headlamp.yaml` | Headlamp | Kubernetes dashboard OIDC and ingress |
| `immich.yaml` | Immich | Photo backup resource limits and storage |
| `jitsi.yaml` | Jitsi | Video conferencing settings and OpenID |
| `loki.yaml` | Loki | Log aggregation retention and resources |
| `longhorn.yaml` | Longhorn | Distributed storage replica count and backups |
| `metallb.yaml` | MetalLB | Load balancer IP pools and L2 advertisements |
| `metrics-server.yaml` | Metrics Server | HPA metrics source configuration |
| `nextcloud.yaml` | Nextcloud | File sync collaboration settings |
| `ntfy.yaml` | ntfy | Push notification server configuration |
| `openbao.yaml` | OpenBao | Secret management deployment settings |
| `prometheus-minimal.yaml` | Prometheus | Minimal Prometheus scrape config |
| `prometheus.yaml` | Prometheus | Full Prometheus, Alertmanager, exporters |
| `tailscale.yaml` | Tailscale | VPN subnet router and exit node config |
| `tempo.yaml` | Tempo | Trace storage resource limits and retention |
| `traefik.yaml` | Traefik | Ingress controller settings and middleware |
| `velero-ui.yaml` | Velero UI | Backup dashboard configuration |
| `velero.yaml` | Velero | Backup schedules and SeaweedFS target |
| `wiredoor-gateway.yaml` | Wiredoor | VPN gateway settings |
| `zulip.yaml` | Zulip | Team chat deployment configuration |

## Usage

Argo CD Applications reference these values via multi-source specs:

```yaml
spec:
  sources:
    - repoURL: https://charts.example.com
      chart: app-name
      targetRevision: 1.0.0
    - repoURL: https://github.com/harrywesterman/twinbox
      ref: values
      path: gitops/values
  destination:
    # values file referenced as: $values/app-name.yaml
```

## Special Cases

Some apps keep their values next to a repo-controlled subtree under `gitops/apps/<app>/` instead of this directory, allowing Kustomize patches to be applied deterministically before Argo CD applies chart output.
