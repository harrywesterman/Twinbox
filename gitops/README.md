# GitOps

Argo CD manifests, platform overlays, and values for the Twinbox Kubernetes cluster.

## Directory Layout

```
gitops/
├── apps/                  # ArgoCD Application manifests
├── databases/             # CloudNativePG cluster templates and secrets
├── install.sh             # ArgoCD bootstrap script
├── platform/              # In-repo overlays (ExternalSecrets, IngressRoutes)
├── routes/                # Traefik route templates
└── values/                # Helm values overrides per app
```

## `apps/`

ArgoCD `Application` resources. Most apps deploy a Helm chart with:

- Multi-source spec: chart repo, `ref: values` from this repo, optional platform overlay.
- Automated sync with `prune` and `selfHeal` enabled.
- `CreateNamespace=true` in sync options.

Some apps use a repo-controlled Kustomize overlay under `gitops/apps/<app>/` so chart output can be patched deterministically before Argo CD applies it.

Bootstrap-facing `ExternalSecret` resources live under `gitops/platform/<app>/` and pull credentials from OpenBao via the `openbao` ClusterSecretStore.

## `databases/`

- `_template/` – CloudNativePG cluster, poolers, scheduled backup, and ExternalSecret templates.
- `authentik/` – Authentik database resources.
- `namespace.yaml` – `databases` namespace definition.

## `platform/`

Per-app overlays applied alongside the Helm chart. Common contents:

- `externalsecret.yaml` – External Secrets Operator resources.
- `ingressroute.yaml` – Traefik IngressRoute definitions.

## `values/`

Helm values files referenced by the ArgoCD Applications via `ref: values`. Named after their app (`grafana.yaml`, etc.). Special-case apps can keep their values next to a repo-controlled Kustomize overlay under `gitops/apps/<app>/` so chart output can be patched deterministically before Argo CD applies it. Authentik uses that pattern.

## `routes/templates/`

Reusable route templates (e.g. Traefik dashboard ExternalSecret).

## `install.sh`

Bootstraps ArgoCD into the cluster:

1. Creates the `argocd` namespace.
2. Installs ArgoCD v3.3.4 via server-side apply.
3. Patches workloads for control-plane tolerations, liveness probes, and idempotent init containers.
4. Waits for all ArgoCD deployments and the application controller StatefulSet to become ready.
