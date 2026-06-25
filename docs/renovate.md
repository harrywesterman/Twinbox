# Renovate

Renovate is configured on this repository to automatically open pull requests when dependencies are outdated. It scans the codebase for version pins and proposes updates through GitHub PRs.

## What is scanned

Renovate runs with the `config:recommended` preset plus:

| File type | Manager | What gets updated |
|-----------|---------|-------------------|
| `gitops/apps/*.yaml` | `argocd` | Helm chart `targetRevision` fields |
| `gitops/optional-apps/*.yaml` | `argocd` | Optional Helm chart versions |
| `gitops/databases/*.yaml` | `argocd` | Database Helm chart versions |
| `config/pinned-defaults.sh` | `regex` | PINNED_*_VERSION vars (GitHub releases) |
| `gitops/values/*.yaml`, `gitops/apps/*/values.yaml` | `regex` | Docker image tags in Helm values |
| `gitops/platform-apps/*/*.yaml` | `regex` | Docker image tags in K8s manifests |
| `package.json` | `npm` | Node.js dependencies |
| `Dockerfile*` | `dockerfile` | Base image tags |
| `.github/workflows/*` | `github-actions` | Action versions |

## Argo CD Helm chart updates

All Twinbox applications are deployed through Argo CD Application manifests that pin a Helm chart version via `targetRevision`.

Example from `gitops/apps/traefik.yaml`:

```yaml
spec:
  sources:
    - repoURL: https://traefik.github.io/charts
      chart: traefik
      targetRevision: "39.0.9"
```

When Renovate detects a newer chart version, it opens a PR that bumps the `targetRevision` field.

### Current chart coverage

Renovate monitors the following Argo CD applications in `gitops/apps/`, `gitops/optional-apps/`, and `gitops/databases/`:

- `alloy`
- `argocd-image-updater`
- `authentik`
- `cloudflare-tunnel`
- `cloudnativepg`
- `crowdsec`
- `external-secrets`
- `grafana`
- `headlamp`
- `immich`
- `jitsi`
- `karakeep`
- `loki`
- `longhorn`
- `metrics-server`
- `nextcloud` (optional)
- `ntfy`
- `openbao`
- `prometheus` & `prometheus-minimal`
- `tempo`
- `traefik`
- `velero` & `velero-ui`
- `zulip`

## Pull request workflow

- Renovate creates **individual PRs** per dependency update.
- PRs are **not auto-merged** — every change must be reviewed and approved manually.
- The PR description includes release notes and a diff of the version change.

## Configuration

The configuration lives in `renovate.json`. It uses:

- **`argocd` manager**: watches `gitops/apps/`, `gitops/optional-apps/`, and `gitops/databases/` for Helm chart `targetRevision` bumps
- **`regex` managers**: scan `config/pinned-defaults.sh` for pinned infra versions, `gitops/values/` for Docker image overrides, and `gitops/platform-apps/` for inline image tags in workload manifests
- **`npm` / `dockerfile` / `github-actions`**: standard ecosystem managers

## Verification

You can verify Renovate is picking up changes by checking the [Renovate dashboard](https://developer.mend.io/github/harrywesterman/Twinbox) or by reviewing open PRs on GitHub.
