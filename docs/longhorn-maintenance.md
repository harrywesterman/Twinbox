# Longhorn Maintenance

Twinbox keeps Longhorn on the worker nodes, but it also tunes the default drain behavior so Talos maintenance can complete on the existing 3-node worker pool.

## Why this matters

Talos upgrades normally drain the node before the new OS image boots. On a Longhorn-backed cluster, the default drain policy can block that drain when the node still carries the last healthy replica of a volume.

Twinbox avoids that dead-end by making the default Longhorn behavior more upgrade-friendly:

- `nodeDrainPolicy: allow-if-replica-is-stopped`
- `detachManuallyAttachedVolumesWhenCordoned: true`

That keeps normal maintenance working on small hardware while still protecting the common case where the node comes back after the upgrade.

The Twinbox Portal Talos-upgrade flow temporarily changes `nodeDrainPolicy` to `always-allow`
while upgrading worker nodes. Worker upgrades also use Talos `--drain=false`, because singleton
workloads such as OpenBao and CloudNativePG intentionally keep PDB protection enabled. The worker
reboots directly, so workloads can be briefly unavailable. The script restores
`allow-if-replica-is-stopped` after the worker phase, on a safe pause, and after failures.

`always-allow` is deliberately not the default. If a worker does not return after its drain,
volumes with only one replica can lose data.

## Upgrade Flow

Use the same pattern for every Talos node:

1. Confirm the target node does not host a manually attached volume that should stay online during maintenance.
2. Accept a short workload interruption while each worker reboots without a Kubernetes drain.
3. Upgrade one Talos node at a time.
4. Wait for the node to rejoin the cluster and for Longhorn instance-manager pods on that node to recover.
5. Move to the next node only after the previous one is healthy again.

## Preflight Checks

Before starting a Talos upgrade, verify:

- Longhorn is still using the Twinbox defaults in `gitops/values/longhorn.yaml`
- no volume on the target node depends on a manually managed attachment
- replicas stored on the target worker are healthy before its controlled reboot

Control-plane drains remain protected. Worker upgrades deliberately skip the drain and compensate
by upgrading one node at a time and waiting for full health before continuing.

The Twinbox Portal admin page at `/admin/updates` applies this policy automatically. It checks
Longhorn volume health before maintenance and after every upgraded Talos node. A non-healthy volume
stops the run and leaves a resumable checkpoint.

Before every worker reboot, the updater also verifies that the worker has no manually attached
Longhorn volumes and that replicas stored on the worker are healthy. A healthy single-replica
volume is allowed in low-memory mode, with an accepted short workload interruption while its worker
reboots.

## Control Plane Topology

Twinbox supports Talos upgrades with any configured control-plane count. Talos 1.13 lifecycle
upgrades preserve node state and etcd membership, so every control-plane node can reboot in place.

- With one or two control-plane nodes, the Kubernetes API and Twinbox Portal can be temporarily
  unavailable while a control-plane node reboots. The Management VM continues the update.
- With three or more control-plane nodes, Twinbox performs the same sequential flow as rolling
  maintenance.
- An odd number of control-plane nodes provides better etcd fault tolerance. Even counts remain
  supported but show an informational warning.

## Recovery Rule

If the target node comes back but Longhorn still reports replica churn or degraded volumes, wait for the cluster to stabilize before continuing the upgrade sequence. On a 3-worker cluster, the safest assumption is still one node at a time.
