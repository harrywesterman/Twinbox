import test from "node:test";
import assert from "node:assert/strict";

import { normalizeVmStorageMap, validateProxmoxCapacity } from "../src/lib/proxmox-capacity.js";

const GB = 1024 * 1024 * 1024;

function storage(node, name, availGb, { shared = false, content = "images" } = {}) {
  return {
    node,
    storage: name,
    active: 1,
    enabled: 1,
    shared: shared ? 1 : 0,
    content,
    total: 200 * GB,
    used: (200 - availGb) * GB,
    avail: availGb * GB,
  };
}

function cluster(overrides = {}) {
  return {
    name: "twinbox-demo",
    start_vmid: 200,
    vm_node_map: { "cp-1": "pve-a", "worker-1": "pve-b" },
    vm_size_map: {
      "cp-1": { cpu: 2, memory_mb: 4096, disk_gb: 20 },
      "worker-1": { cpu: 4, memory_mb: 8192, disk_gb: 60 },
    },
    vm_storage_map: { "cp-1": "local-lvm", "worker-1": "local-lvm" },
    ...overrides,
  };
}

test("storage map chooses the preferred eligible storage per selected host", () => {
  const result = normalizeVmStorageMap(
    {},
    ["cp-1", "worker-1"],
    { "cp-1": "pve-a", "worker-1": "pve-b" },
    [storage("pve-a", "fast-zfs", 80), storage("pve-b", "local-lvm", 40)],
    "local-lvm"
  );

  assert.deepEqual(result, {
    ok: true,
    value: { "cp-1": "fast-zfs", "worker-1": "local-lvm" },
  });
});

test("storage map rejects inactive or non-image storage", () => {
  const result = normalizeVmStorageMap({ "cp-1": "backup" }, ["cp-1"], { "cp-1": "pve-a" }, [
    storage("pve-a", "backup", 100, { content: "backup,iso" }),
  ]);

  assert.equal(result.ok, false);
  assert.match(result.error, /not active VM-image storage/i);
});

test("capacity validation reserves running VM maxmem and management VM regardless of state", () => {
  const result = validateProxmoxCapacity({
    cluster: cluster({
      vm_node_map: { "cp-1": "pve-a" },
      vm_size_map: { "cp-1": { cpu: 2, memory_mb: 8192, disk_gb: 20 } },
      vm_storage_map: { "cp-1": "local-lvm" },
    }),
    nodes: [{ node: "pve-a", maxmem: 32 * GB, mem: 0 }],
    vms: [
      {
        node: "pve-a",
        name: "twinbox-demo-mgt",
        tags: "twinbox;management",
        vmid: 100,
        status: "stopped",
        mem: 0,
        maxmem: 8 * GB,
      },
      {
        node: "pve-a",
        name: "off-vm",
        vmid: 101,
        status: "stopped",
        mem: 0,
        maxmem: 32 * GB,
      },
      {
        node: "pve-a",
        name: "other-running",
        vmid: 102,
        status: "running",
        mem: 4 * GB,
        maxmem: 8 * GB,
      },
    ],
    storages: [storage("pve-a", "local-lvm", 100)],
  });

  assert.deepEqual(result, { ok: true });
});

test("capacity validation fails when planned memory exceeds host capacity", () => {
  const result = validateProxmoxCapacity({
    cluster: cluster({
      vm_node_map: { "cp-1": "pve-a" },
      vm_size_map: { "cp-1": { cpu: 2, memory_mb: 8192, disk_gb: 20 } },
      vm_storage_map: { "cp-1": "local-lvm" },
    }),
    nodes: [{ node: "pve-a", maxmem: 16 * GB, mem: 10 * GB }],
    vms: [
      {
        node: "pve-a",
        name: "twinbox-demo-mgt",
        tags: "twinbox;management",
        vmid: 100,
        status: "running",
        mem: 2 * GB,
        maxmem: 4 * GB,
      },
      {
        node: "pve-a",
        name: "other-running",
        vmid: 103,
        status: "running",
        mem: 8 * GB,
        maxmem: 8 * GB,
      },
    ],
    storages: [storage("pve-a", "local-lvm", 100)],
  });

  assert.equal(result.ok, false);
  assert.match(result.error, /Insufficient RAM on pve-a/);
});

test("shared storage capacity is counted once across hosts", () => {
  const result = validateProxmoxCapacity({
    cluster: cluster({
      vm_storage_map: { "cp-1": "shared-zfs", "worker-1": "shared-zfs" },
    }),
    nodes: [
      { node: "pve-a", maxmem: 32 * GB, mem: 0 },
      { node: "pve-b", maxmem: 32 * GB, mem: 0 },
    ],
    storages: [
      storage("pve-a", "shared-zfs", 70, { shared: true }),
      storage("pve-b", "shared-zfs", 70, { shared: true }),
    ],
  });

  assert.equal(result.ok, false);
  assert.match(result.error, /80 GiB requested, 70 GiB free/);
});

test("retry capacity replaces disks from the existing Twinbox generation", () => {
  const current = cluster({
    vm_node_map: { "cp-1": "pve-a" },
    vm_size_map: { "cp-1": { cpu: 2, memory_mb: 4096, disk_gb: 40 } },
    vm_storage_map: { "cp-1": "local-lvm" },
  });
  const result = validateProxmoxCapacity({
    cluster: current,
    existingCluster: current,
    nodes: [{ node: "pve-a", maxmem: 16 * GB, mem: 4 * GB }],
    vms: [
      {
        node: "pve-a",
        name: "twinbox-demo-cp-1",
        vmid: 200,
        status: "running",
        mem: 4 * GB,
        maxmem: 4 * GB,
      },
    ],
    storages: [storage("pve-a", "local-lvm", 5)],
  });

  assert.deepEqual(result, { ok: true });
});
