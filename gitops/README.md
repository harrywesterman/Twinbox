# GitOps

Argo CD manifests, platform overlays, and values for the Twinbox Kubernetes cluster.

## Directory Layout

```
gitops/
├── apps/                  # Argo CD Application manifests and app-local overlays
├── databases/             # CloudNativePG cluster templates and bootstrap resources
├── install.sh             # Argo CD bootstrap script
├── platform/              # Cluster and platform overlays
├── platform-apps/         # App-specific manifests applied by manager scripts
└── values/                # Helm values overrides per app
```

## `apps/`

Argo CD `Application` resources. Most apps deploy a Helm chart with:

- Multi-source spec: chart repo, `ref: values` from this repo, optional platform overlay.
- Automated sync with `prune` and `selfHeal` enabled.
- `CreateNamespace=true` in sync options.

Some apps use a repo-controlled subtree under `gitops/apps/<app>/` or a standalone ApplicationSet manifest under `gitops/apps/<app>.yaml` so chart output can be patched deterministically before Argo CD applies it. The current patterns are:

- `gitops/apps/dashy.yaml` - ApplicationSet for the Dashy admin launcher with cluster-specific ingress hostnames.
- `gitops/apps/opencloud.yaml` - ApplicationSet for OpenCloud with repo-local platform-apps overlay and cluster-specific hostnames.
- `gitops/apps/authentik/` - Helm values plus Kustomize patches for the Authentik chart.
- `gitops/apps/prometheus/` - Kustomize manifests for Prometheus alerts.
- `gitops/apps/alloy.yaml` - Grafana Alloy collector Application.
- `gitops/apps/audiobookshelf.yaml` - Audiobookshelf ApplicationSet.
- `gitops/apps/cloudflare-tunnel.yaml` - Cloudflare Tunnel Application.
- `gitops/apps/cloudnativepg.yaml` - CloudNativePG operator Application.
- `gitops/apps/crowdsec.yaml` - CrowdSec security engine Application.
- `gitops/apps/external-secrets.yaml` - External Secrets Operator Application.
- `gitops/apps/freshrss.yaml` - FreshRSS ApplicationSet.
- `gitops/apps/grafana.yaml` - Grafana Application.
- `gitops/apps/headlamp.yaml` - Headlamp dashboard Application.
- `gitops/apps/hedgedoc.yaml` - HedgeDoc ApplicationSet.
- `gitops/apps/immich.yaml` - Immich ApplicationSet.
- `gitops/apps/jitsi.yaml` - Jitsi ApplicationSet.
- `gitops/apps/karakeep.yaml` - Karakeep ApplicationSet.
- `gitops/apps/loki.yaml` - Loki log aggregation Application.
- `gitops/apps/longhorn.yaml` - Longhorn storage Application.
- `gitops/apps/metallb.yaml` - MetalLB load balancer Application.
- `gitops/apps/metrics-server.yaml` - Kubernetes Metrics Server Application.
- `gitops/apps/n8n.yaml` - n8n workflow automation ApplicationSet.
- `gitops/apps/netbird-routing-peers.yaml` - NetBird routing peers Application.
- `gitops/apps/nextcloud.yaml` - Nextcloud ApplicationSet.
- `gitops/apps/ntfy.yaml` - ntfy push notifications Application.
- `gitops/apps/openbao.yaml` - OpenBao secret management Application.
- `gitops/apps/openwebui.yaml` - OpenWebUI ApplicationSet.
- `gitops/apps/outline.yaml` - Outline ApplicationSet.
- `gitops/apps/paperless.yaml` - Paperless ApplicationSet.
- `gitops/apps/pixelfed.yaml` - Pixelfed ApplicationSet.
- `gitops/apps/platform-ingress.yaml` - Shared platform ingress resources.
- `gitops/apps/prometheus-minimal.yaml` - Minimal Prometheus scrape config Application.
- `gitops/apps/searxng.yaml` - SearXNG ApplicationSet.
- `gitops/apps/stirling-pdf.yaml` - Stirling PDF ApplicationSet.
- `gitops/apps/tailscale.yaml` - Tailscale VPN Application.
- `gitops/apps/tempo.yaml` - Tempo trace storage Application.
- `gitops/apps/traefik.yaml` - Traefik ingress controller Application.
- `gitops/apps/twinbox-portal.yaml` - Twinbox Portal Application.
- `gitops/apps/vaultwarden.yaml` - Vaultwarden ApplicationSet.
- `gitops/apps/velero.yaml` - Velero backup Application.
- `gitops/apps/velero-ui.yaml` - Velero UI Application.
- `gitops/apps/wiredoor-gateway.yaml` - Wiredoor gateway Application.
- `gitops/apps/zulip.yaml` - Zulip ApplicationSet.

Bootstrap-facing `ExternalSecret` resources live under `gitops/platform/<app>/` and pull credentials from OpenBao via the `openbao` ClusterSecretStore.

## `databases/`

- `_template/` - CloudNativePG cluster, poolers, scheduled backup, and ExternalSecret templates.
- `authentik/` - Authentik database resources.
- `immich/` - Immich database resources.
- `longhorn-single-storageclass.yaml` - StorageClass used by single-replica clusters.
- `namespace.yaml` - `databases` namespace definition.

## `platform/`

Cluster-scoped and shared platform overlays. Common contents:

- `argocd/` - Argo CD ingress and cluster access resources.
- `authentik/` - Authentik ingress and callback resources.
- `management-consoles/` - Shared console resources and callbacks.
- `traefik/` - Traefik ingress and dashboard resources.
- `velero/` - Backup-related resources.

## `values/`

Helm values files referenced by the Argo CD Applications via `ref: values`. Named after their app (`grafana.yaml`, etc.). See [values/README.md](values/README.md) for the full list.

Special-case apps can keep their values next to a repo-controlled subtree under `gitops/apps/<app>/` so chart output can be patched deterministically before Argo CD applies it.

## `routes/`

Traefik route templates. See [routes/README.md](routes/README.md).

## `platform-apps/`

App-specific Kubernetes manifests that are rendered or applied directly by the manager scripts. Common examples include:

- `audiobookshelf/` - Audiobookshelf deployment, service, ingress, and PVC.
- `cloudnativepg-barman-cloud/` - CloudNativePG Barman Cloud backup configuration.
- `dashy/` - Dashy deployment, service, ingress, PVC, and kustomization.
- `freshrss/` - FreshRSS deployment, service, ingress, and database wiring.
- `garage/` - Garage S3-compatible object storage deployment.
- `grafana/` - Grafana ingress and secret wiring.
- `headlamp/` - Headlamp ingress and secret wiring.
- `hedgedoc/` - HedgeDoc deployment, service, ingress, and database wiring.
- `immich/` - Immich namespace, PVC, ingress, and database secret wiring.
- `jitsi/` - Jitsi deployment, service, ingress, and OpenID configuration.
- `karakeep/` - Karakeep deployment, service, ingress, and database wiring.
- `loki/` - Loki ingress and auth middleware.
- `n8n/` - n8n deployment, service, ingress, and database wiring.
- `netbird-routing-peers/` - NetBird routing peer deployment.
- `nextcloud/` - Nextcloud deployment, service, ingress, and database wiring.
- `ntfy/` - ntfy ingress and kustomization.
- `opencloud/` - OpenCloud deployment, collaboration services, ingress, and bootstrap config.
- `openwebui/` - OpenWebUI deployment, service, ingress, and PVC.
- `outline/` - Outline deployment, service, ingress, and database wiring.
- `paperless/` - Paperless deployment, service, ingress, and database wiring.
- `pgadmin4/` - pgAdmin 4 namespace, deployment, service, PVC, ingress, and secret wiring.
- `pixelfed/` - Pixelfed deployment, service, ingress, and database wiring.
- `prometheus/` - Prometheus ingress and alert rules.
- `searxng/` - SearXNG deployment, service, and ingress.
- `stirling-pdf/` - Stirling PDF deployment, service, and ingress.
- `tailscale/` - Tailscale secret wiring.
- `twinbox-portal/` - Twinbox Portal deployment, service, ingress, config, and per-user preference storage.
- `vaultwarden/` - Vaultwarden deployment, service, ingress, and database wiring.
- `velero-ui/` - Velero UI namespace, ingress, and secret wiring.
- `wiredoor-gateway/` - Wiredoor gateway secret wiring.
- `zulip/` - Zulip deployment, service, ingress, and database wiring.

## `install.sh`

Bootstraps ArgoCD into the cluster:

1. Creates the `argocd` namespace.
2. Installs ArgoCD using the pinned version from `config/pinned-defaults.sh` via server-side apply.
3. Patches workloads for control-plane tolerations, liveness probes, and idempotent init containers.
4. Waits for all ArgoCD deployments and the application controller StatefulSet to become ready.
