# Expanded dependency automation and in-cluster image scanning

## Goal

Automate the routine dependency maintenance that was still manual, and make the security
state of every running component visible. The user wants dependency updates to flow
automatically except for genuinely risky changes, and wants to see the vulnerabilities that
GitHub's dependency graph cannot report.

## Scope

### 1. Renovate auto-merge expansion

`renovate.json` now auto-merges, after the required `Verify / verify` check:

- Stable npm `devDependencies` and runtime `dependencies` patch/minor updates (14-day soak,
  not on `0.x`).
- Helm chart and container image patch/minor/digest updates (7-day soak, not on `0.x`).
- Existing root tooling lock file maintenance and `verify.yml` action digests.
- Security fixes (see the security automerge design).

Major versions, prereleases, `0.x` dependencies, everything in `config/pinned-defaults.sh`
(the `github-releases` datasource: Talos, Kubernetes, Cilium, …), nested lock file
maintenance, and workflow changes outside `verify.yml` remain manual. The previous
"critical runtime patch is never auto-merged" rule was reduced to a faster schedule; those
patches now auto-merge like other non-major Helm updates.

### 2. Trivy Operator

`gitops/apps/trivy-operator.yaml` deploys the Aqua Trivy Operator Helm chart from
`https://aquasecurity.github.io/helm-charts` into `trivy-system`, managed by Argo CD and
tracked by Renovate. `gitops/values/trivy-operator.yaml` limits concurrent scan jobs, keeps
unfixed findings visible, and enables the ServiceMonitor for Prometheus. The
`install-trivy-operator` wizard step applies the application, so new clusters get
continuous scanning of every running image.

### 3. Floating tag removal

`ghcr.io/toeverything/affine:stable` was the only genuinely floating deployed image tag
(the `bitnami/*:latest` occurrences are vendored chart annotations, and `nginx:latest` only
appears in comments). It is now pinned to its current digest as
`ghcr.io/toeverything/affine:stable@sha256:b649f5ce…` in the affine deployment and migration
job. `ghcr.io/jippi/docker-pixelfed` already uses a dated build tag and is left as is.

## Why

GitHub's dependency graph for this repository only tracks npm, GitHub Actions, and pypi.
Helm charts and container images are invisible to Dependabot, so there was no CVE feed for
the large majority of Twinbox components. Trivy Operator closes that visibility gap, while
the Renovate expansion keeps versions current without a human merging every routine bump.

## Operational boundary

Every merge to `main` still rebuilds the Twinbox images and can restart Portal, Agents,
Dashy, and the Jitsi broker. Auto-merging Helm and image updates therefore also triggers
Argo CD syncs and pod restarts without human review for non-major, non-`0.x` changes.
Management VM deployment remains manual.
