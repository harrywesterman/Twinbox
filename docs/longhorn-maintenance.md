# Longhorn Maintenance

Twinbox keeps Longhorn on the worker nodes, but it also tunes the default drain behavior so Talos maintenance can complete on the existing 3-node worker pool.

## Why this matters

Talos upgrades drain the node before the new OS image boots. On a Longhorn-backed cluster, the default drain policy can block that drain when the node still carries the last healthy replica of a volume.

Twinbox avoids that dead-end by making the default Longhorn behavior more upgrade-friendly:

- `nodeDrainPolicy: allow-if-replica-is-stopped`
- `detachManuallyAttachedVolumesWhenCordoned: true`

That keeps normal maintenance working on small hardware while still protecting the common case where the node comes back after the upgrade.

## Upgrade Flow

Use the same pattern for every Talos node:

1. Confirm the target node does not host a manually attached volume that should stay online during maintenance.
2. Let Longhorn detach any manually attached volumes when the node is cordoned.
3. Upgrade one Talos node at a time.
4. Wait for the node to rejoin the cluster and for Longhorn instance-manager pods on that node to recover.
5. Move to the next node only after the previous one is healthy again.

## Preflight Checks

Before starting a Talos upgrade, verify:

- Longhorn is still using the Twinbox defaults in `gitops/values/longhorn.yaml`
- no volume on the target node depends on a manually managed attachment
- the cluster has enough healthy replicas on the remaining workers to tolerate one node being offline

If a node still refuses to drain, stop and inspect the Longhorn volume placement before forcing the upgrade. The goal is to keep the upgrade safe and repeatable, not to bypass the safety model entirely.

## Recovery Rule

If the target node comes back but Longhorn still reports replica churn or degraded volumes, wait for the cluster to stabilize before continuing the upgrade sequence. On a 3-worker cluster, the safest assumption is still one node at a time.
