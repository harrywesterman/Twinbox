# Renovate Security Automerge Design

## Goal

Close the gap where Renovate detected no vulnerabilities and no security fix ever
auto-merged, so that safe security fixes land automatically while runtime, cluster, and
GitOps upgrades stay under human control.

## Why the previous setup missed alerts

Renovate read GitHub Dependabot alerts via `vulnerabilityAlerts`, but the Dependency
Dashboard showed no Vulnerabilities section and no `security`-labelled PR had ever been
opened. The `security` label referenced by `addLabels` did not exist in the repository,
and GitHub-only detection depends on the Renovate GitHub App having Dependabot-alert read
access. Open alerts were left unaddressed: `qs` (medium) in `manager-api`, `portal`, and
`twinbox-agents`, and `elliptic` (low) in the Nextcloud file-action build tooling.

## Design

- `osvVulnerabilityAlerts: true` adds OSV detection for direct dependencies, independent of
  GitHub App permissions.
- The `security` label is created so `addLabels` succeeds.
- `vulnerabilityAlerts` sets `automerge: true` with a `"3 days"` `minimumReleaseAge` and
  `internalChecksFilter: "strict"`. A fix auto-merges only after the required
  `Verify / verify` check succeeds and platform auto-merge completes the squash merge.
- GitHub's dependency graph covers npm dependencies (including transitive ones through
  lockfiles) and Dockerfile/Compose images, so those security fixes can auto-merge. Helm
  charts, Argo CD `targetRevision` pins, and GitOps images are not in the graph and remain
  manual by construction.

## Operational boundary

Every merge to `main` still rebuilds the Twinbox images and can restart Portal, Agents,
Dashy, and the Jitsi broker. Automerged security fixes therefore trigger the same rebuild
path as any other merge. Management VM deployment remains manual and still requires waiting
for successful image publication before pulling the selected SHA tag.

## Immediate remediation

`qs` was updated to `6.16.0` in the three affected lockfiles. The `elliptic` alert has no
patched release; it is a build-time development dependency of the Nextcloud file action and
is dismissed as accepted risk until upstream provides a fix.
