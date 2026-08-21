# Mailu storage-node selection: disk + capacity aware

**Date:** 2026-08-21
**Status:** Approved

## Problem

`choose_mailu_storage_node()` in `categories/apps/steps/install-mailu/run.sh`
picks the alphabetically-first Ready worker node (`head -n1`). It does not
consider free disk space or whether the node can actually host the Mailu
workloads. In the `prd` cluster install this chose `twinbox-prd-worker-1`,
which had the most free disk of the three workers (618 GiB) but was already at
its pod limit (110/110). Five pinned Mailu deployments (admin, postfix,
dovecot, rspamd, webmail) remained `Pending`, the 10-minute wait timed out, and
the `install-mailu` step failed.

## Design

Rewrite `choose_mailu_storage_node()` to be disk- and capacity-aware. Node
selection remains label-driven (no change to the ApplicationSet or the
`twinbox.io/mailu-storage-node` mechanism).

### Selection algorithm

1. **Reuse existing label.** If a Ready node already carries
   `twinbox.io/mailu-storage-node=<slug>`, keep using it (idempotent; repairs
   reuse the same node and re-annotations won't rewrite the Argo CD secret).

2. **Candidate filter.** Nodes must be: Ready, schedulable
   (`unschedulable == false`), and not control-plane.

3. **Capacity filter (must-fit).** Candidates must have room for the pinned
   Mailu workload set (~6 deployments with the storage-node nodeSelector:
   front, admin, postfix, dovecot, rspamd, webmail):
   - free pod slots ≥ **8** (maxPods − currently bound pods, including
     Completed pods that still count against the kubelet limit — exactly the
     failure mode seen on worker-1);
   - free allocatable CPU ≥ Mailu CPU requests (sum of `resources.requests` of
     the pinned set);
   - free allocatable memory ≥ Mailu memory requests (same sum).

4. **Rank by free disk.** Among candidates that pass the capacity filter,
   prefer the node with the most free disk as reported by the Longhorn node
   CR (`nodes.longhorn.io` → `status.diskStatus[*].storageAvailable`), since
   `mailu-storage` lives on the `longhorn-single` storage class.

5. **Fallback signal.** If the Longhorn CRD is unavailable, fall back to the
   k8s node `status.allocatable["ephemeral-storage"]`.

6. **Fail loudly.** If no candidate passes the capacity filter, fail with a
   diagnostic listing each candidate node and why it was rejected (pod slots,
   CPU, memory, or disk signal) instead of silently picking the first node.

### Scope

- Only `categories/apps/steps/install-mailu/run.sh` (the
  `choose_mailu_storage_node()` function plus a small helper to read Longhorn /
  allocatable disk signals).
- No change to `gitops/optional-apps/mailu.yaml`, `gitops/apps/mailu.yaml`, or
  `gitops/values/mailu.yaml` — the label annotation flow stays identical.
- Pinned set estimated request budget lives near the selector so the future
  pinned components are easy to update.

## Testing

- Existing tests in `tests/test_mailu_gitops.py` keep passing (the installer
  assertions — `choose_mailu_storage_node`, `twinbox.io/mailu-storage-node`,
  etc. — must still hold).
- Add assertions that the new function: reads Longhorn `storageAvailable`
  (with ephemeral-storage fallback), filters on pod slots / CPU / memory, and
  fails with a per-node rejection diagnostic.
- Run `python3 -m pytest -q tests` and `bash -n categories/apps/steps/install-mailu/run.sh`.

## Deployment

- This runs on the Management VM (worker container). Per AGENTS.md: commit +
  push to `main`, wait for the "Publish Docker Images" workflow to succeed,
  then refresh with `docker compose pull && docker compose up -d`.
- The live `prd` cluster still needs `install-mailu` re-run (repoint the
  storage-node label to a node with capacity, e.g. worker-3) — separate from
  this code change.