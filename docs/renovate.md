# Renovate

Renovate is configured on this repository to automatically open pull requests when dependencies are outdated. It scans the codebase for version pins and proposes updates through GitHub PRs.

## What is scanned

Renovate runs with the `config:recommended` preset plus an explicit Argo CD manager that watches `gitops/apps/*.yaml`.

| File type | Manager | What gets updated |
|-----------|---------|-------------------|
| `gitops/apps/*.yaml` | `argocd` | Helm chart `targetRevision` fields (e.g. `traefik`, `prometheus`, `immich`, `authentik`) |
| `package.json` / `requirements.txt` / etc. | built-in | Node, Python, and other ecosystem dependencies |

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

Renovate monitors the following Argo CD applications in `gitops/apps/`:

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
- `nextcloud`
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

The configuration lives in `renovate.json`:

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": [
    "config:recommended"
  ],
  "argocd": {
    "fileMatch": [
      "gitops/apps/.*\\.yaml$"
    ]
  }
}
```

To add more paths, extend the `argocd.fileMatch` array.

## Verification

You can verify Renovate is picking up changes by checking the [Renovate dashboard](https://developer.mend.io/github/harrywesterman/Twinbox) or by reviewing open PRs on GitHub.
