# Renovate Automerge Design

## Goal

Continuously merge low-risk dependency maintenance while keeping runtime, cluster, and
GitOps upgrades under human control.

## Design

Renovate uses PR-based squash auto-merge behind the required `verify` status check. The
allowlist contains stable npm development dependency patch/minor updates, root-only tooling
lockfile maintenance, and action digest updates in the read-only Verify workflow. Npm
auto-merge waits 14 days after publication where release timestamps are available.

All runtime dependencies, nested lockfiles, Docker, Helm, GitOps, pinned infrastructure, and
privileged workflow changes remain manual. Security updates are raised immediately and only
auto-merge if they independently match the allowlist.

GitHub protects `main` with required pull requests, a strict required status check, and a
GitHub Actions bypass for the generated image-reference commit. Because that bypass is
actor-wide, a contract test ensures only the Docker publish workflow has repository content
write permission.

## Operational boundary

The existing behavior that rebuilds all images and refreshes internal image pins after every
merge is retained. This may restart Portal, Agents, Dashy, and the Jitsi broker. Management VM
deployment remains manual and continues to require waiting for successful image publication
before pulling the selected SHA tag.

The allowlist is reviewed after at least two weeks and ten automatic merges. It is never
expanded implicitly based only on elapsed time.
