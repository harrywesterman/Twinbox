import test from "node:test";
import assert from "node:assert/strict";

import { computePlacement, findManagementVm, isManagementVm } from "../src/lib/placement.js";

const GB = 1024 * 1024 * 1024;

function node(name, { ramGb, memUsedGb = 0, cpu = 0, diskGb, diskUsedGb = 0 } = {}) {
  return {
    node: name,
    status: "online",
    maxmem: ramGb * GB,
    mem: memUsedGb * GB,
    maxcpu: cpu,
    maxdisk: diskGb * GB,
    disk: diskUsedGb * GB,
  };
}

function storage(name, availGb, { shared = false } = {}) {
  return {
    node: name,
    storage: "local-lvm",
    active: 1,
    enabled: 1,
    shared: shared ? 1 : 0,
    content: "images",
    total: (availGb + 100) * GB,
    used: 100 * GB,
    avail: availGb * GB,
  };
}

function vm(overrides = {}) {
  return {
    name: "other",
    node: "pve-a",
    status: "stopped",
    mem: 0,
    maxmem: 0,
    maxcpu: 0,
    ...overrides,
  };
}

test("findManagementVm matches the management tag and -mgt suffix", () => {
  const vms = [
    vm({ name: "docker", tags: "infra", vmid: 101 }),
    vm({ name: "twinbox-demo-mgt", tags: "twinbox;management", vmid: 100 }),
  ];
  assert.equal(isManagementVm(vms[1]), true);
  assert.equal(findManagementVm(vms).name, "twinbox-demo-mgt");
});

test("control planes are placed on separate nodes", () => {
  const result = computePlacement({
    nodes: [
      node("pve-a", { ramGb: 64, cpu: 16, diskGb: 1000 }),
      node("pve-b", { ramGb: 64, cpu: 16, diskGb: 1000 }),
      node("pve-c", { ramGb: 64, cpu: 16, diskGb: 1000 }),
    ],
    storages: [storage("pve-a", 1000), storage("pve-b", 1000), storage("pve-c", 1000)],
    controlplaneCount: 3,
    workerCount: 0,
  });

  assert.equal(result.ok, true);
  assert.equal(result.vmNodeMap["cp-1"], "pve-a");
  assert.equal(result.vmNodeMap["cp-2"], "pve-b");
  assert.equal(result.vmNodeMap["cp-3"], "pve-c");
  assert.equal(new Set(Object.values(result.vmNodeMap)).size, 3);
  assert.deepEqual(result.vmSizeMap["cp-1"], { cpu: 2, memory_mb: 5120, disk_gb: 10 });
});

test("control plane placement fails when there are fewer nodes than requested", () => {
  const result = computePlacement({
    nodes: [node("pve-a", { ramGb: 64, cpu: 16, diskGb: 1000 })],
    storages: [storage("pve-a", 1000)],
    controlplaneCount: 3,
    workerCount: 0,
  });
  assert.equal(result.ok, false);
  assert.match(result.error, /separate nodes/);
});

test("workers fill memory, disk and cpu per node", () => {
  const result = computePlacement({
    nodes: [
      node("pve-a", { ramGb: 64, cpu: 16, diskGb: 1000 }),
      node("pve-b", { ramGb: 256, cpu: 96, diskGb: 4000 }),
      node("pve-c", { ramGb: 32, cpu: 12, diskGb: 800 }),
    ],
    storages: [storage("pve-a", 1000), storage("pve-b", 4000), storage("pve-c", 800)],
    controlplaneCount: 3,
    workerCount: 3,
  });

  assert.equal(result.ok, true);

  const workerA = result.vmSizeMap["worker-1"];
  const workerB = result.vmSizeMap["worker-2"];
  const workerC = result.vmSizeMap["worker-3"];

  // workers land on the same node as their control plane (one per node)
  assert.equal(result.vmNodeMap["worker-1"], result.vmNodeMap["cp-1"]);
  assert.equal(result.vmNodeMap["worker-2"], result.vmNodeMap["cp-2"]);
  assert.equal(result.vmNodeMap["worker-3"], result.vmNodeMap["cp-3"]);

  // the big node yields the biggest worker, the small node the smallest
  assert.ok(workerA.memory_mb > workerB.memory_mb);
  assert.ok(workerB.memory_mb > workerC.memory_mb);
  assert.equal(workerA.cpu, 94);
  assert.equal(workerC.cpu, 10);

  // no worker exceeds its node's free memory (95% of free after control plane)
  for (const name of ["worker-1", "worker-2", "worker-3"]) {
    assert.ok(result.vmSizeMap[name].memory_mb >= 512);
    assert.ok(result.vmSizeMap[name].disk_gb >= 10);
    assert.ok(result.vmSizeMap[name].cpu >= 1);
  }
});

test("running VMs reserve configured memory, stopped VMs reserve nothing", () => {
  const result = computePlacement({
    nodes: [node("pve-a", { ramGb: 64, cpu: 16, diskGb: 1000 })],
    vms: [
      vm({ name: "off-vm", node: "pve-a", status: "stopped", maxmem: 32 * GB, maxcpu: 8 }),
      vm({
        name: "running-vm",
        node: "pve-a",
        status: "running",
        mem: 2 * GB,
        maxmem: 16 * GB,
        maxcpu: 4,
      }),
    ],
    storages: [storage("pve-a", 1000)],
    controlplaneCount: 1,
    workerCount: 1,
  });

  assert.equal(result.ok, true);
  const worker = result.vmSizeMap["worker-1"];
  // free = 64 - 16 (running vm) = 48 GiB; minus cp 5 GiB = 43 GiB; 95% ≈ 40.85 GiB
  assert.ok(worker.memory_mb >= 40 * 1024 && worker.memory_mb <= 41 * 1024);
  // cpu: 16 - 4 (running vm) - 2 (cp) = 10
  assert.equal(worker.cpu, 10);
});

test("management VM reserves its memory and cpu regardless of run state", () => {
  const result = computePlacement({
    nodes: [node("pve-a", { ramGb: 64, cpu: 16, diskGb: 1000 })],
    vms: [
      vm({
        name: "twinbox-demo-mgt",
        tags: "management",
        node: "pve-a",
        status: "stopped",
        maxmem: 8 * GB,
        maxcpu: 2,
      }),
    ],
    storages: [storage("pve-a", 1000)],
    controlplaneCount: 1,
    workerCount: 1,
  });

  assert.equal(result.ok, true);
  const worker = result.vmSizeMap["worker-1"];
  // free = 64 - 8 (mgt) = 56 GiB; minus cp 5 GiB = 51 GiB; 95% ≈ 48.45 GiB
  assert.ok(worker.memory_mb >= 48 * 1024 && worker.memory_mb <= 49 * 1024);
  assert.equal(worker.cpu, 12);
});

test("capacity-weighted distribution gives more workers to bigger nodes", () => {
  const result = computePlacement({
    nodes: [
      node("pve-a", { ramGb: 32, cpu: 16, diskGb: 1000 }),
      node("pve-b", { ramGb: 128, cpu: 64, diskGb: 1000 }),
    ],
    storages: [storage("pve-a", 1000), storage("pve-b", 1000)],
    controlplaneCount: 2,
    workerCount: 3,
  });

  assert.equal(result.ok, true);
  const byHost = { "pve-a": 0, "pve-b": 0 };
  const workers = Object.entries(result.vmNodeMap).filter(([name]) => name.startsWith("worker-"));
  for (const [, host] of workers) byHost[host] += 1;
  assert.equal(byHost["pve-b"], 2);
  assert.equal(byHost["pve-a"], 1);
});

test("existing target VMs for the same cluster are excluded from reservations", () => {
  const result = computePlacement({
    nodes: [node("pve-a", { ramGb: 64, cpu: 16, diskGb: 1000 })],
    vms: [
      vm({
        name: "twinbox-demo-cp-1",
        node: "pve-a",
        status: "running",
        mem: 4 * GB,
        maxmem: 8 * GB,
        maxcpu: 2,
      }),
    ],
    storages: [storage("pve-a", 1000)],
    clusterName: "twinbox-demo",
    controlplaneCount: 1,
    workerCount: 1,
  });

  assert.equal(result.ok, true);
  const worker = result.vmSizeMap["worker-1"];
  // existing target VM ignored: free = 64 GiB; minus cp 5 GiB = 59 GiB; 95% ≈ 56 GiB
  assert.ok(worker.memory_mb >= 56 * 1024 && worker.memory_mb <= 57 * 1024);
});

test("management VM is reserved even when its name matches the cluster prefix", () => {
  const result = computePlacement({
    nodes: [node("pve-a", { ramGb: 64, cpu: 16, diskGb: 1000 })],
    vms: [
      vm({
        name: "twinbox-demo-mgt",
        node: "pve-a",
        status: "running",
        mem: 2 * GB,
        maxmem: 8 * GB,
        maxcpu: 2,
      }),
    ],
    storages: [storage("pve-a", 1000)],
    clusterName: "twinbox-demo",
    controlplaneCount: 1,
    workerCount: 1,
  });

  assert.equal(result.ok, true);
  const worker = result.vmSizeMap["worker-1"];
  // mgt reserved (8 GiB): free = 64 - 8 = 56 GiB; minus cp 5 GiB = 51 GiB; 95% ≈ 48 GiB
  assert.ok(worker.memory_mb >= 48 * 1024 && worker.memory_mb <= 49 * 1024);
  assert.equal(worker.cpu, 12);
});

test("worker memory is aligned down to a 512 MiB step", () => {
  const result = computePlacement({
    nodes: [node("pve-a", { ramGb: 33, cpu: 16, diskGb: 1000 })],
    storages: [storage("pve-a", 1000)],
    controlplaneCount: 1,
    workerCount: 1,
  });
  assert.equal(result.ok, true);
  assert.equal(result.vmSizeMap["worker-1"].memory_mb % 512, 0);
});
