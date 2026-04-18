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

Some apps use a repo-controlled subtree under `gitops/apps/<app>/` so chart output can be patched deterministically before Argo CD applies it. The current patterns are:

- `gitops/apps/authentik/` - Helm values plus Kustomize patches for the Authentik chart.
- `gitops/apps/prometheus/` - Kustomize manifests for Prometheus alerts.

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

Helm values files referenced by the Argo CD Applications via `ref: values`. Named after their app (`grafana.yaml`, etc.). Special-case apps can keep their values next to a repo-controlled subtree under `gitops/apps/<app>/` so chart output can be patched deterministically before Argo CD applies it.

## `platform-apps/`

App-specific Kubernetes manifests that are rendered or applied directly by the manager scripts. Common examples include:

- `dashy/` - Dashy deployment, service, ingress, PVC, and kustomization.
- `grafana/` - Grafana ingress and secret wiring.
- `headlamp/` - Headlamp ingress and secret wiring.
- `immich/` - Immich namespace, PVC, ingress, and database secret wiring.
- `loki/` - Loki ingress and auth middleware.
- `ntfy/` - ntfy ingress and kustomization.
- `pgadmin4/` - pgAdmin 4 namespace, deployment, service, PVC, ingress, and secret wiring.
- `twinbox-portal/` - Twinbox Portal deployment, service, ingress, config, and per-user preference storage.
- `velero-ui/` - Velero UI namespace, ingress, and secret wiring.
- `prometheus/` - Prometheus ingress and alert rules.
- `tailscale/` - Tailscale secret wiring.
- `wiredoor-gateway/` - Wiredoor gateway secret wiring.

## `install.sh`

Bootstraps ArgoCD into the cluster:

1. Creates the `argocd` namespace.
2. Installs ArgoCD v3.3.4 via server-side apply.
3. Patches workloads for control-plane tolerations, liveness probes, and idempotent init containers.
4. Waits for all ArgoCD deployments and the application controller StatefulSet to become ready.
