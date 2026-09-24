# Renovate

Renovate is configured on this repository to automatically open pull requests when dependencies are outdated. It scans the codebase for version pins and proposes updates through GitHub PRs.

Renovate is the repository's only dependency update bot. Dependabot version updates are
disabled by keeping `.github/dependabot.yml` absent. GitHub Dependabot alerts remain enabled
as a read-only vulnerability source, but Dependabot security updates remain disabled so that
Dependabot does not create pull requests. Renovate reads the alerts and creates the security
PRs described below.

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
- `trivy-operator`
- `velero` & `velero-ui`
- `zulip`

## Pull request workflow

- Renovate creates individual or dependency-grouped PRs and includes release notes and a
  version diff.
- Only the explicit low-risk allowlist below is auto-merged. All other updates remain open
  for manual review.
- Auto-merge always uses a pull request and squash merge. Renovate never pushes an update
  branch directly to `main`.
- GitHub only completes auto-merge after the required `Verify / verify` check succeeds and
  the PR branch is up to date with `main`.
- Renovate rebases eligible PRs that fall behind. A PR remains open for manual handling when
  CI fails or a conflict cannot be resolved automatically.

### Automatic update allowlist

| Update | Schedule | Additional guard |
|--------|----------|------------------|
| Stable npm `devDependencies` and runtime `dependencies` patch/minor | Weekdays before 06:00 | Current version must be 1.0.0 or newer; release must be at least 14 days old |
| Helm charts and container images patch/minor/digest | Weekdays before 06:00 | Current version must be 1.0.0 or newer, so `0.x` charts stay manual; release must be at least 7 days old |
| Root `package-lock.json` maintenance | Monday before 06:00 | Root package contains development tooling only |
| GitHub Actions digest updates in `verify.yml` | Weekdays before 06:00 | Initial digest pinning remains manual |
| Security / vulnerability fixes | Bypasses the schedule | Fix must be at least 3 days old; auto-merges after `Verify / verify` succeeds |

Critical runtime Helm charts (`external-secrets`, `jitsi-meet`, `kube-prometheus-stack`,
`openbao`, and `traefik`) still get their patch PRs raised faster before 06:00 on weekdays,
and they auto-merge through the Helm/image rule above once `Verify / verify` succeeds.

The following updates are never auto-merged (a PR is still opened for review):

- Major versions, prereleases, and any dependency currently on `0.x`
- Talos, Kubernetes, Cilium, and all other versions in `config/pinned-defaults.sh` (the
  `github-releases` datasource)
- Nested lockfile maintenance for Manager API/Web/Worker, Portal, Twinbox Agents, and app
  actions
- GitHub Actions changes outside `.github/workflows/verify.yml`, including the image publish
  and Pages workflows
- Vendored Helm charts committed under an application (for example the Authentik dependency
  charts)

Security updates bypass the normal branch schedule. Renovate reads GitHub Dependabot alerts
and, for direct dependencies, OSV alerts (`osvVulnerabilityAlerts`); it labels the PRs
`security` and assigns `harrywesterman`. A fix that has been released for at least three days
auto-merges once the required `Verify / verify` check succeeds.

GitHub's dependency graph tracks npm dependencies (including transitive ones, via lockfiles)
and Dockerfile/Compose images, so CVE-driven security fixes there are automatic. Helm charts
and Argo CD `targetRevision` pins are not in the dependency graph, so they have no CVE feed;
they still auto-merge through the ordinary Helm/image rule above whenever a non-major,
non-`0.x` release is available.

### Repository safeguards

The `main` ruleset requires pull requests, the `verify` status check, and an up-to-date
branch. Repository auto-merge is enabled. A dedicated deploy key has a ruleset bypass so the
`Publish Docker Images` workflow can write its generated `[skip ci]` image-reference commit.

The bypass belongs to the dedicated write deploy key `Twinbox image refs workflow`. Its
private key is stored only in the Actions secret `TWINBOX_IMAGE_REFS_DEPLOY_KEY` and is only
passed to the `update-refs` checkout. A contract test also enforces that
`docker-publish.yml` is the only workflow with `contents: write`. Rotate both halves of the
deploy key together and treat any additional workflow write permission as a
security-sensitive manual change.

Repository administrators retain the existing direct-`main` bypass required by the Twinbox
maintenance workflow. Renovate has no bypass and must always satisfy the pull-request and
`verify` rules.

Every push to `main`, including a Renovate merge, still rebuilds the Twinbox images and
refreshes the repository image pins. Portal, Agents, Dashy, and the Jitsi broker can restart
through Argo CD. The Management VM is not refreshed automatically; continue to wait for a
successful `Publish Docker Images` run and explicitly update its image tag before pulling the
stack.

### Rollout and expansion

Evaluate the policy after at least two weeks and at least ten successful automatic merges.
Review failed PRs, conflicts, regressions, publish results, and Argo CD health. Expanding the
allowlist, especially to runtime or GitOps updates, requires a separate reviewed policy
change.

## Configuration

The configuration lives in `renovate.json`. It uses:

- **`argocd` manager**: watches `gitops/apps/`, `gitops/optional-apps/`, and `gitops/databases/` for Helm chart `targetRevision` bumps
- **`regex` managers**: scan `config/pinned-defaults.sh` for pinned infra versions, `gitops/values/` for Docker image overrides, and `gitops/platform-apps/` for inline image tags in workload manifests
- **`npm` / `dockerfile` / `github-actions`**: standard ecosystem managers
- **`vulnerabilityAlerts` + `osvVulnerabilityAlerts`**: GitHub Dependabot alerts plus OSV
  alerts for direct dependencies; fixes auto-merge after a three-day soak once the required
  `verify` check passes

Validate policy changes with:

```bash
python3 -m pytest -q tests/test_renovate_policy.py
npx --yes --package renovate renovate-config-validator renovate.json
```

## Verification

You can verify Renovate is picking up changes by checking the [Renovate dashboard](https://developer.mend.io/github/harrywesterman/Twinbox) or by reviewing open PRs on GitHub.
