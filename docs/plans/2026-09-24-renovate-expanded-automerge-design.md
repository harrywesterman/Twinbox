# Continuous dependency automation

## Goal

Keep GitHub continuously up to date with dependency and security fixes, so Argo CD can roll
the upgraded `main` out to every cluster. Updates should flow automatically except for
genuinely risky changes.

## Renovate auto-merge

`renovate.json` auto-merges, after the required `Verify / verify` check:

- Stable npm `devDependencies` and runtime `dependencies` patch/minor updates (14-day soak,
  not on `0.x`).
- Helm chart and container image patch/minor/digest updates (7-day soak, not on `0.x`).
- Root tooling lock file maintenance and `verify.yml` action digests.
- Security fixes, detected through GitHub Dependabot alerts plus OSV.

Major versions, prereleases, `0.x` dependencies, everything in `config/pinned-defaults.sh`
(the `github-releases` datasource: Talos, Kubernetes, Cilium, …), nested lock file
maintenance, and workflow changes outside `verify.yml` remain manual.

## Continuous scheduling

Updates are no longer limited to a Monday or weekday-before-06:00 window. Renovate may
create and update pull requests at any time; security updates already bypassed the schedule.
The previous "critical runtime patch is raised only on weekdays" rule was removed with the
schedule restriction.

## Floating tag removal

`ghcr.io/toeverything/affine:stable` was the only genuinely floating deployed image tag
(the `bitnami/*:latest` occurrences are vendored chart annotations, and `nginx:latest` only
appears in comments). It is pinned to its current digest as
`ghcr.io/toeverything/affine:stable@sha256:b649f5ce…` in the affine deployment and migration
job. `ghcr.io/jippi/docker-pixelfed` already uses a dated build tag and is left as is.

## Operational boundary

Every merge to `main` rebuilds the Twinbox images and can restart Portal, Agents, Dashy, and
the Jitsi broker. Auto-merging Helm and image updates therefore also triggers Argo CD syncs
and pod restarts without human review for non-major, non-`0.x` changes. Management VM
deployment remains manual.
