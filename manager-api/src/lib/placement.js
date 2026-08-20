import {
  findManagementVm,
  isManagementVm,
  isVmStorageResource,
  normalizeStorageResource,
} from "./proxmox-capacity.js";

const MB = 1024 * 1024;
const GB = 1024 * 1024 * 1024;

export const PLACEMENT_DEFAULTS = {
  reserveFraction: 0.05,
  cpCpu: 2,
  cpMemoryMb: 5120,
  cpDiskGb: 10,
  workerCpuMin: 1,
  workerMemoryMinMb: 512,
  workerDiskMinGb: 10,
  memoryAlignMb: 512,
};

function text(value) {
  return String(value ?? "").trim();
}

function lower(value) {
  return text(value).toLowerCase();
}

function number(value, fallback = 0) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function roundInteger(value, fallback = 0) {
  return Math.round(number(value, fallback));
}

function alignDown(value, step) {
  const resolved = Math.floor(number(value, 0));
  const aligned = Math.floor(resolved / step) * step;
  return Math.max(0, aligned);
}

export { findManagementVm, isManagementVm } from "./proxmox-capacity.js";

function vmName(vm = {}) {
  return lower(text(vm.name || vm.vm_name || vm.id));
}

function isTargetVm(vm, clusterName) {
  if (isManagementVm(vm)) return false;
  const prefix = lower(text(clusterName));
  if (!prefix) return false;
  return vmName(vm).startsWith(`${prefix}-`);
}

function resolveNodeStorage(nodeName, storages = []) {
  const entries = (Array.isArray(storages) ? storages : [])
    .map(normalizeStorageResource)
    .filter((entry) => entry.node === nodeName && isVmStorageResource(entry));
  if (entries.length === 0) return null;
  return entries.sort(
    (left, right) => right.avail - left.avail || left.storage.localeCompare(right.storage)
  )[0];
}

function apportionWorkers(workerCount, nodes) {
  const counts = new Map(nodes.map((node) => [node.name, 0]));
  if (workerCount <= 0 || nodes.length === 0) return counts;

  const base = Math.floor(workerCount / nodes.length);
  for (const node of nodes) counts.set(node.name, base);

  const remaining = workerCount - base * nodes.length;
  const byFreeMem = [...nodes].sort(
    (left, right) => right.freeMemMb - left.freeMemMb || left.name.localeCompare(right.name)
  );
  for (let index = 0; index < remaining; index += 1) {
    const node = byFreeMem[index % byFreeMem.length];
    counts.set(node.name, counts.get(node.name) + 1);
  }
  return counts;
}

export function computePlacement({
  nodes = [],
  vms = [],
  storages = [],
  controlplaneCount = 3,
  workerCount = 0,
  clusterName = "",
  options = {},
} = {}) {
  const opts = { ...PLACEMENT_DEFAULTS, ...(options || {}) };
  const reserve = number(opts.reserveFraction, PLACEMENT_DEFAULTS.reserveFraction);
  const cpCpu = Math.max(1, roundInteger(opts.cpCpu, PLACEMENT_DEFAULTS.cpCpu));
  const cpMemoryMb = Math.max(0, roundInteger(opts.cpMemoryMb, PLACEMENT_DEFAULTS.cpMemoryMb));
  const cpDiskGb = Math.max(0, roundInteger(opts.cpDiskGb, PLACEMENT_DEFAULTS.cpDiskGb));
  const workerCpuMin = Math.max(
    1,
    roundInteger(opts.workerCpuMin, PLACEMENT_DEFAULTS.workerCpuMin)
  );
  const workerMemoryMinMb = Math.max(
    0,
    roundInteger(opts.workerMemoryMinMb, PLACEMENT_DEFAULTS.workerMemoryMinMb)
  );
  const workerDiskMinGb = Math.max(
    0,
    roundInteger(opts.workerDiskMinGb, PLACEMENT_DEFAULTS.workerDiskMinGb)
  );
  const alignMb = Math.max(1, roundInteger(opts.memoryAlignMb, PLACEMENT_DEFAULTS.memoryAlignMb));

  const mgtVm = findManagementVm(vms);
  const mgtNode = text(mgtVm?.node || mgtVm?.statusnode || "");

  const nodeList = (Array.isArray(nodes) ? nodes : [])
    .map((entry) => {
      const name = text(entry.node || entry.name || entry.id);
      const storage = resolveNodeStorage(name, storages);
      return {
        name,
        maxmemMb: number(entry.maxmem, 0) / MB,
        memMb: number(entry.mem, 0) / MB,
        maxcpu: number(entry.maxcpu, 0),
        freeDiskGb: storage
          ? number(storage.avail, 0) / GB
          : Math.max(0, (number(entry.maxdisk, 0) - number(entry.disk, 0)) / GB),
        storageId: storage ? storage.storage : text(entry.storage_pool || "local-lvm"),
      };
    })
    .filter((entry) => entry.name);

  if (nodeList.length === 0) {
    return { ok: false, error: "No Proxmox nodes available for placement" };
  }

  const vmsList = Array.isArray(vms) ? vms : [];
  const hostVms = new Map(nodeList.map((node) => [node.name, []]));
  for (const vm of vmsList) {
    const vmNode = text(vm.node || vm.statusnode || "");
    if (!hostVms.has(vmNode)) continue;
    if (isTargetVm(vm, clusterName)) continue;
    hostVms.get(vmNode).push(vm);
  }

  const warnings = [];
  const stateByNode = new Map();
  for (const node of nodeList) {
    const vmsHere = hostVms.get(node.name) || [];
    let runningMemMb = 0;
    let reservedMemMb = 0;
    let reservedCpu = 0;

    for (const vm of vmsHere) {
      const running = lower(vm.status || vm.qmpstatus) === "running";
      const isMgt = isManagementVm(vm) && node.name === mgtNode;
      const configuredMemMb =
        (number(vm.maxmem, 0) > 0 ? number(vm.maxmem, 0) : number(vm.mem, 0)) / MB;
      const currentMemMb = number(vm.mem, 0) / MB;
      const configuredCpu = number(vm.maxcpu, 0) > 0 ? number(vm.maxcpu, 0) : number(vm.cpu, 0);

      if (isMgt) {
        reservedMemMb += configuredMemMb;
        reservedCpu += configuredCpu;
        if (running) runningMemMb += currentMemMb;
        continue;
      }
      if (running) {
        runningMemMb += currentMemMb;
        reservedMemMb += configuredMemMb;
        reservedCpu += configuredCpu;
      }
    }

    const hostOverheadMb = Math.max(0, node.memMb - runningMemMb);
    const freeMemMb = Math.max(0, node.maxmemMb - hostOverheadMb - reservedMemMb);
    const freeCpu = Math.max(0, node.maxcpu - reservedCpu);
    if (node.maxcpu <= 0) {
      warnings.push(
        `Proxmox node ${node.name} reports no CPU capacity; workers there fall back to ${workerCpuMin} vCPU`
      );
    }

    stateByNode.set(node.name, {
      ...node,
      freeMemMb,
      freeCpu,
    });
  }

  const cpCount = Math.max(0, roundInteger(controlplaneCount, 0));
  const sortedNodes = [...nodeList].sort(
    (left, right) =>
      stateByNode.get(right.name).freeMemMb - stateByNode.get(left.name).freeMemMb ||
      left.name.localeCompare(right.name)
  );

  const chosenCpNodes = [];
  for (const node of sortedNodes) {
    if (chosenCpNodes.length >= cpCount) break;
    const state = stateByNode.get(node.name);
    if (state.freeMemMb >= cpMemoryMb && state.freeDiskGb >= cpDiskGb && state.freeCpu >= cpCpu) {
      chosenCpNodes.push(node);
    }
  }

  if (cpCount > 0 && chosenCpNodes.length < cpCount) {
    return {
      ok: false,
      error: `Not enough Proxmox nodes to place ${cpCount} control plane(s) on separate nodes: only ${chosenCpNodes.length} node(s) available`,
    };
  }

  const vmNodeMap = {};
  const vmSizeMap = {};
  const vmStorageMap = {};

  for (let index = 0; index < cpCount; index += 1) {
    const node = chosenCpNodes[index];
    const state = stateByNode.get(node.name);
    state.freeMemMb = Math.max(0, state.freeMemMb - cpMemoryMb);
    state.freeDiskGb = Math.max(0, state.freeDiskGb - cpDiskGb);
    state.freeCpu = Math.max(0, state.freeCpu - cpCpu);
    const name = `cp-${index + 1}`;
    vmNodeMap[name] = node.name;
    vmSizeMap[name] = { cpu: cpCpu, memory_mb: cpMemoryMb, disk_gb: cpDiskGb };
    vmStorageMap[name] = state.storageId;
  }

  const workerTotal = Math.max(0, roundInteger(workerCount, 0));
  const workerCounts = apportionWorkers(
    workerTotal,
    sortedNodes.map((node) => ({
      name: node.name,
      freeMemMb: stateByNode.get(node.name).freeMemMb,
    }))
  );

  let workerIndex = 1;
  for (const node of sortedNodes) {
    const count = workerCounts.get(node.name) || 0;
    if (count <= 0) continue;
    const state = stateByNode.get(node.name);
    const usableMemMb = Math.max(0, state.freeMemMb * (1 - reserve));
    const usableDiskGb = Math.max(0, state.freeDiskGb * (1 - reserve));

    for (let offset = 0; offset < count; offset += 1) {
      const name = `worker-${workerIndex}`;
      workerIndex += 1;
      const memoryMb = Math.max(workerMemoryMinMb, alignDown(usableMemMb / count, alignMb));
      const diskGb = Math.max(workerDiskMinGb, Math.floor(usableDiskGb / count));
      const cpu = Math.max(workerCpuMin, Math.floor(state.freeCpu / count));

      vmNodeMap[name] = node.name;
      vmSizeMap[name] = { cpu, memory_mb: memoryMb, disk_gb: diskGb };
      vmStorageMap[name] = state.storageId;
    }
  }

  return { ok: true, vmNodeMap, vmSizeMap, vmStorageMap, warnings };
}
