const MB_PER_GB = 1024;
const MIN_SCALE_PERCENT = 0;
const DEFAULT_SCALE_PERCENT = 30;
const MAX_SCALE_PERCENT = 100;
const MAX_FOOTPRINT_MULTIPLIER = 4;

const CONTROLPLANE_MEMORY_MB = 2048;
const CONTROLPLANE_DISK_GB = 10;
const WORKER_DISK_MIN_GB = 40;
const WORKER_MEMORY_DEFAULT_MB = 8192;

export const PROVISION_AUTOSCALED_FIELDS = [
  'controlplane_count',
  'worker_count',
  'cpu_cores',
  'memory_mb',
];

function toNumber(value, fallback = 0) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function clamp(value, min, max) {
  return Math.min(Math.max(value, min), max);
}

function roundToStep(value, step) {
  return Math.round(value / step) * step;
}

function roundToInteger(value) {
  return Math.round(value);
}

function sanitizeStepInputs(stepInputs = []) {
  return Array.isArray(stepInputs) ? stepInputs : [];
}

function getInputDefault(stepInputs, inputId, fallback = 0) {
  const input = sanitizeStepInputs(stepInputs).find((candidate) => candidate.id === inputId);
  return toNumber(input?.default, fallback);
}

function getInputBounds(stepInputs, inputId, fallback = {}) {
  const input = sanitizeStepInputs(stepInputs).find((candidate) => candidate.id === inputId) || {};
  return {
    min: Number.isFinite(Number(input.min)) ? Number(input.min) : fallback.min,
    max: Number.isFinite(Number(input.max)) ? Number(input.max) : fallback.max,
  };
}

function normalizeScalePercent(value) {
  return clamp(roundToInteger(toNumber(value, DEFAULT_SCALE_PERCENT)), MIN_SCALE_PERCENT, MAX_SCALE_PERCENT);
}

function normalizeHostName(value) {
  return String(value || '').trim();
}

export function formatMemoryMb(value) {
  const mb = Math.max(0, roundToInteger(toNumber(value, 0)));
  if (mb >= MB_PER_GB) {
    const gb = mb / MB_PER_GB;
    if (Number.isInteger(gb)) {
      return `${gb} GB`;
    }
    return `${gb.toFixed(gb >= 10 ? 0 : 1)} GB`;
  }
  return `${mb} MB`;
}

export function summarizeProxmoxClusterResources(resources) {
  const nodes = Array.isArray(resources?.nodes)
    ? resources.nodes
    : Array.isArray(resources)
      ? resources
      : [];
  const vms = Array.isArray(resources?.vms) ? resources.vms : [];
  const activeVmCounts = vms.reduce((accumulator, entry) => {
    const node = normalizeHostName(entry?.node);
    const status = String(entry?.status || entry?.qmpstatus || '').trim().toLowerCase();
    if (!node || (status && status !== 'running')) {
      return accumulator;
    }
    accumulator[node] = (accumulator[node] || 0) + 1;
    return accumulator;
  }, {});

  const summary = nodes.reduce((accumulator, entry) => {
    const maxMem = toNumber(entry?.maxmem, 0);
    const usedMem = toNumber(entry?.mem, 0);
    const maxDisk = toNumber(entry?.maxdisk, 0);
    const usedDisk = toNumber(entry?.disk, 0);
    const maxCpu = toNumber(entry?.maxcpu, 0);
    const cpuLoad = clamp(toNumber(entry?.cpu, 0), 0, 1);

    accumulator.nodeCount += 1;
    accumulator.totalMemoryMb += maxMem > 0 ? maxMem / (1024 * 1024) : 0;
    accumulator.usedMemoryMb += usedMem > 0 ? usedMem / (1024 * 1024) : 0;
    accumulator.totalDiskGb += maxDisk > 0 ? maxDisk / (1024 * 1024 * 1024) : 0;
    accumulator.usedDiskGb += usedDisk > 0 ? usedDisk / (1024 * 1024 * 1024) : 0;
    accumulator.totalCpuCores += maxCpu > 0 ? maxCpu : 0;
    accumulator.usedCpuCores += maxCpu > 0 ? maxCpu * cpuLoad : 0;
    return accumulator;
  }, {
    nodeCount: 0,
    totalMemoryMb: 0,
    usedMemoryMb: 0,
    freeMemoryMb: 0,
    totalDiskGb: 0,
    usedDiskGb: 0,
    freeDiskGb: 0,
    totalCpuCores: 0,
    usedCpuCores: 0,
    freeCpuCores: 0,
  });

  summary.freeMemoryMb = Math.max(0, summary.totalMemoryMb - summary.usedMemoryMb);
  summary.freeDiskGb = Math.max(0, summary.totalDiskGb - summary.usedDiskGb);
  summary.freeCpuCores = Math.max(0, summary.totalCpuCores - summary.usedCpuCores);

  return {
    nodes: nodes
      .map((entry) => ({
        ...entry,
        activeVmCount: activeVmCounts[normalizeHostName(entry?.node || entry?.name || entry?.id)] || 0,
      }))
      .sort((left, right) => normalizeHostName(left?.node || left?.name || left?.id).localeCompare(
        normalizeHostName(right?.node || right?.name || right?.id),
        undefined,
        { sensitivity: 'base' },
      )),
    summary,
  };
}

function buildBaseline(stepInputs) {
  const controlplaneCount = Math.max(1, roundToInteger(getInputDefault(stepInputs, 'controlplane_count', 1)));
  const workerCount = Math.max(0, roundToInteger(getInputDefault(stepInputs, 'worker_count', 0)));
  const nodeCount = Math.max(1, controlplaneCount + workerCount);
  const cpuCores = Math.max(1, roundToInteger(getInputDefault(stepInputs, 'cpu_cores', 2)));
  const workerMemoryMb = Math.max(512, roundToStep(getInputDefault(stepInputs, 'memory_mb', WORKER_MEMORY_DEFAULT_MB), 512));
  const scalePercent = normalizeScalePercent(getInputDefault(stepInputs, 'scale_percent', DEFAULT_SCALE_PERCENT));

  return {
    scalePercent,
    controlplaneCount,
    workerCount,
    nodeCount,
    cpuCores,
    workerMemoryMb,
    totalCpuCores: nodeCount * cpuCores,
    totalWorkerMemoryMb: workerCount * workerMemoryMb,
    bounds: {
      controlplane_count: getInputBounds(stepInputs, 'controlplane_count', { min: 1, max: 15 }),
      worker_count: getInputBounds(stepInputs, 'worker_count', { min: 0, max: 200 }),
      cpu_cores: getInputBounds(stepInputs, 'cpu_cores', { min: 1, max: 64 }),
      memory_mb: getInputBounds(stepInputs, 'memory_mb', { min: 512, max: 1048576 }),
    },
  };
}

function deriveCapacityMultiplier(baseline, resources) {
  const summary = resources?.summary || null;
  if (!summary) {
    return 3.5;
  }

  const memoryMultiplier = summary.freeMemoryMb > 0 ? summary.freeMemoryMb / Math.max(1, baseline.totalWorkerMemoryMb || baseline.workerCount || 1) : 0.5;
  const diskMultiplier = summary.freeDiskGb > 0 ? summary.freeDiskGb / Math.max(1, baseline.workerCount || 1) : 0.5;
  const cpuMultiplier = summary.freeCpuCores > 0 ? summary.freeCpuCores / Math.max(1, baseline.totalCpuCores) : 0.5;

  return clamp(Math.min(memoryMultiplier, diskMultiplier, cpuMultiplier), 0.5, MAX_FOOTPRINT_MULTIPLIER);
}

function interpolate(start, end, percent) {
  return start + (end - start) * clamp(percent / 100, 0, 1);
}

function roundOrFallback(value, fallback, bounds) {
  const rounded = roundToInteger(value);
  if (Number.isFinite(bounds?.min) && rounded < bounds.min) return bounds.min;
  if (Number.isFinite(bounds?.max) && rounded > bounds.max) return bounds.max;
  return Number.isFinite(rounded) ? rounded : fallback;
}

function roundMemoryOrFallback(value, fallback, bounds) {
  const rounded = roundToStep(value, 512);
  if (Number.isFinite(bounds?.min) && rounded < bounds.min) return bounds.min;
  if (Number.isFinite(bounds?.max) && rounded > bounds.max) return bounds.max;
  return Number.isFinite(rounded) ? rounded : fallback;
}

function calculateFootprintMultiplier(scalePercent, baseline, resources) {
  const capacityMultiplier = deriveCapacityMultiplier(baseline, resources);
  if (scalePercent <= DEFAULT_SCALE_PERCENT) {
    return interpolate(0.5, 1, scalePercent * (100 / DEFAULT_SCALE_PERCENT));
  }
  return interpolate(1, capacityMultiplier, ((scalePercent - DEFAULT_SCALE_PERCENT) * 100) / (MAX_SCALE_PERCENT - DEFAULT_SCALE_PERCENT));
}

export function getProvisionNodeCount(stepInputs = [], currentValues = {}) {
  const baseline = buildBaseline(stepInputs);
  const controlplaneCount = Number.isFinite(Number(currentValues.controlplane_count))
    ? Number(currentValues.controlplane_count)
    : baseline.controlplaneCount;
  const workerCount = Number.isFinite(Number(currentValues.worker_count))
    ? Number(currentValues.worker_count)
    : baseline.workerCount;

  return Math.max(1, controlplaneCount + workerCount);
}

export function buildScaledProvisionInputs(scalePercent, stepInputs, currentValues = {}, dirtyFields = new Set(), resources = null) {
  const baseline = buildBaseline(stepInputs);
  const resolvedScale = normalizeScalePercent(scalePercent);
  const footprintMultiplier = calculateFootprintMultiplier(resolvedScale, baseline, resources);
  const nodeMultiplier = 1 + (footprintMultiplier - 1) * 0.55;
  const sizeMultiplier = footprintMultiplier / nodeMultiplier;

  const targetNodeCount = Math.max(1, roundToInteger(baseline.nodeCount * nodeMultiplier));
  const targetControlplanes = clamp(
    roundToInteger(targetNodeCount * (baseline.controlplaneCount / baseline.nodeCount)),
    1,
    targetNodeCount,
  );
  const targetWorkers = Math.max(0, targetNodeCount - targetControlplanes);
  const targetCpuCores = roundOrFallback(
    baseline.cpuCores * sizeMultiplier,
    baseline.cpuCores,
    baseline.bounds.cpu_cores,
  );
  const targetMemoryMb = roundMemoryOrFallback(
    baseline.workerMemoryMb * sizeMultiplier,
    baseline.workerMemoryMb,
    baseline.bounds.memory_mb,
  );

  const existing = currentValues && typeof currentValues === 'object' ? currentValues : {};
  const isDirty = (field) => dirtyFields instanceof Set && dirtyFields.has(field);

  return {
    ...existing,
    scale_percent: resolvedScale,
    controlplane_count: isDirty('controlplane_count')
      ? roundOrFallback(existing.controlplane_count ?? baseline.controlplaneCount, baseline.controlplaneCount, baseline.bounds.controlplane_count)
      : targetControlplanes,
    worker_count: isDirty('worker_count')
      ? roundOrFallback(existing.worker_count ?? baseline.workerCount, baseline.workerCount, baseline.bounds.worker_count)
      : targetWorkers,
    cpu_cores: isDirty('cpu_cores')
      ? roundOrFallback(existing.cpu_cores ?? baseline.cpuCores, baseline.cpuCores, baseline.bounds.cpu_cores)
      : targetCpuCores,
    memory_mb: isDirty('memory_mb')
      ? roundMemoryOrFallback(existing.memory_mb ?? baseline.workerMemoryMb, baseline.workerMemoryMb, baseline.bounds.memory_mb)
      : targetMemoryMb,
  };
}

export function buildProvisionScaleSummary(scalePercent, stepInputs, currentValues = {}, resources = null) {
  const baseline = buildBaseline(stepInputs);
  const resolvedScale = normalizeScalePercent(scalePercent ?? currentValues.scale_percent ?? baseline.scalePercent);
  const resourceSummary = resources?.summary || null;
  const controlplaneCount = Math.max(1, roundToInteger(toNumber(currentValues.controlplane_count, baseline.controlplaneCount)));
  const workerCount = Math.max(0, roundToInteger(toNumber(currentValues.worker_count, baseline.workerCount)));
  const cpuCores = Math.max(1, roundToInteger(toNumber(currentValues.cpu_cores, baseline.cpuCores)));
  const workerMemoryMb = Math.max(512, roundToStep(toNumber(currentValues.memory_mb, baseline.workerMemoryMb), 512));
  const totalNodes = Math.max(1, controlplaneCount + workerCount);
  const availableWorkerDiskGb = Math.max(
    0,
    (resourceSummary?.freeDiskGb || 0) - (controlplaneCount * CONTROLPLANE_DISK_GB),
  );
  const workerDiskPerVm = workerCount > 0
    ? Math.max(
      WORKER_DISK_MIN_GB,
      Math.round((availableWorkerDiskGb / Math.max(1, workerCount)) * (resolvedScale / 100)),
    )
    : WORKER_DISK_MIN_GB;

  const totalCpuCores = totalNodes * cpuCores;
  const totalWorkerMemoryMb = workerCount * workerMemoryMb;
  const totalWorkerDiskGb = workerCount * workerDiskPerVm;

  return {
    scale_percent: resolvedScale,
    total_nodes: totalNodes,
    controlplane_count: controlplaneCount,
    worker_count: workerCount,
    cpu_cores: cpuCores,
    worker_memory_mb: workerMemoryMb,
    controlplane_memory_mb: CONTROLPLANE_MEMORY_MB,
    controlplane_disk_gb: CONTROLPLANE_DISK_GB,
    worker_disk_gb: workerDiskPerVm,
    total_cpu_cores: totalCpuCores,
    total_worker_memory_mb: totalWorkerMemoryMb,
    total_worker_disk_gb: totalWorkerDiskGb,
    total_controlplane_memory_mb: controlplaneCount * CONTROLPLANE_MEMORY_MB,
    total_controlplane_disk_gb: controlplaneCount * CONTROLPLANE_DISK_GB,
    total_memory_mb: totalWorkerMemoryMb + (controlplaneCount * CONTROLPLANE_MEMORY_MB),
    total_disk_gb: totalWorkerDiskGb + (controlplaneCount * CONTROLPLANE_DISK_GB),
    capacity: resourceSummary,
    memory_share_percent: resourceSummary?.freeMemoryMb > 0
      ? Math.round(((totalWorkerMemoryMb + (controlplaneCount * CONTROLPLANE_MEMORY_MB)) / resourceSummary.freeMemoryMb) * 100)
      : null,
    disk_share_percent: resourceSummary?.freeDiskGb > 0
      ? Math.round(((totalWorkerDiskGb + (controlplaneCount * CONTROLPLANE_DISK_GB)) / resourceSummary.freeDiskGb) * 100)
      : null,
    cpu_share_percent: resourceSummary?.freeCpuCores > 0
      ? Math.round((totalCpuCores / resourceSummary.freeCpuCores) * 100)
      : null,
  };
}

export function buildProvisionHostCards(resources) {
  const summary = summarizeProxmoxClusterResources(resources);

  return summary.nodes.map((entry, index) => {
    const name = normalizeHostName(entry?.node || entry?.name || entry?.id || `host-${index + 1}`);
    const totalMemoryMb = toNumber(entry?.maxmem, 0) / (1024 * 1024);
    const usedMemoryMb = toNumber(entry?.mem, 0) / (1024 * 1024);
    const totalDiskGb = toNumber(entry?.maxdisk, 0) / (1024 * 1024 * 1024);
    const usedDiskGb = toNumber(entry?.disk, 0) / (1024 * 1024 * 1024);
    const totalCpuCores = toNumber(entry?.maxcpu, 0);
    const usedCpuCores = clamp(totalCpuCores * clamp(toNumber(entry?.cpu, 0), 0, 1), 0, totalCpuCores);

    return {
      id: name,
      name,
      status: String(entry?.status || 'unknown'),
      activeVmCount: Math.max(0, roundToInteger(toNumber(entry?.activeVmCount, 0))),
      totalMemoryMb,
      usedMemoryMb,
      freeMemoryMb: Math.max(0, totalMemoryMb - usedMemoryMb),
      totalDiskGb,
      usedDiskGb,
      freeDiskGb: Math.max(0, totalDiskGb - usedDiskGb),
      totalCpuCores,
      usedCpuCores,
      freeCpuCores: Math.max(0, totalCpuCores - usedCpuCores),
    };
  }).sort((left, right) => normalizeHostName(left?.name || left?.id).localeCompare(
    normalizeHostName(right?.name || right?.id),
    undefined,
    { sensitivity: 'base' },
  ));
}

export function buildProvisionVmPlan(stepInputs, currentValues = {}) {
  const baseline = buildBaseline(stepInputs);
  const values = currentValues && typeof currentValues === 'object' ? currentValues : {};
  const controlplaneCount = Math.max(1, roundToInteger(toNumber(values.controlplane_count, baseline.controlplaneCount)));
  const workerCount = Math.max(0, roundToInteger(toNumber(values.worker_count, baseline.workerCount)));
  const cpuCores = Math.max(1, roundToInteger(toNumber(values.cpu_cores, baseline.cpuCores)));
  const workerMemoryMb = Math.max(512, roundToStep(toNumber(values.memory_mb, baseline.workerMemoryMb), 512));
  const startVmid = Math.max(100, roundToInteger(toNumber(values.start_vmid, getInputDefault(stepInputs, 'start_vmid', 200))));

  const plan = [];
  let vmid = startVmid;

  for (let index = 1; index <= controlplaneCount; index += 1) {
    plan.push({
      id: `cp-${index}`,
      name: `cp-${index}`,
      label: `Control plane ${index}`,
      type: 'controlplane',
      vmid,
      cpu: cpuCores,
      memory_mb: CONTROLPLANE_MEMORY_MB,
      disk_gb: CONTROLPLANE_DISK_GB,
    });
    vmid += 1;
  }

  for (let index = 1; index <= workerCount; index += 1) {
    plan.push({
      id: `worker-${index}`,
      name: `worker-${index}`,
      label: `Worker ${index}`,
      type: 'worker',
      vmid,
      cpu: cpuCores,
      memory_mb: workerMemoryMb,
      disk_gb: WORKER_DISK_MIN_GB,
    });
    vmid += 1;
  }

  return plan;
}

function chooseBestHostForVm(vm, hostCards) {
  let bestHost = null;
  let bestScore = -1;

  for (const host of hostCards) {
    const cpuScore = host.freeCpuCores > 0 ? host.freeCpuCores / Math.max(1, vm.cpu) : 0;
    const memoryScore = host.freeMemoryMb > 0 ? host.freeMemoryMb / Math.max(1, vm.memory_mb) : 0;
    const diskScore = host.freeDiskGb > 0 ? host.freeDiskGb / Math.max(1, vm.disk_gb) : 0;
    const score = (diskScore * 3) + cpuScore + memoryScore;

    if (score > bestScore) {
      bestScore = score;
      bestHost = host;
    }
  }

  return bestHost;
}

export function suggestVmNodeMap(vmPlan, hostCards, currentMap = {}) {
  const plan = Array.isArray(vmPlan) ? vmPlan : [];
  const hosts = Array.isArray(hostCards) ? hostCards.map((host) => ({ ...host })) : [];
  const assignments = {};
  const hostLookup = new Map(hosts.map((host) => [host.id, host]));

  for (const vm of plan) {
    const preservedHost = typeof currentMap?.[vm.name] === 'string' ? normalizeHostName(currentMap[vm.name]) : '';
    const host = preservedHost && hostLookup.has(preservedHost)
      ? hostLookup.get(preservedHost)
      : chooseBestHostForVm(vm, hosts);

    if (!host) {
      assignments[vm.name] = preservedHost || '';
      continue;
    }

    assignments[vm.name] = host.id;
    host.freeCpuCores = Math.max(0, host.freeCpuCores - vm.cpu);
    host.freeMemoryMb = Math.max(0, host.freeMemoryMb - vm.memory_mb);
    host.freeDiskGb = Math.max(0, host.freeDiskGb - vm.disk_gb);
  }

  return assignments;
}

function buildVmSizeMap(vmPlan, hostCards, currentMap = {}, scalePercent = DEFAULT_SCALE_PERCENT) {
  const plan = Array.isArray(vmPlan) ? vmPlan : [];
  const hosts = Array.isArray(hostCards) ? hostCards.map((host) => ({ ...host })) : [];
  const hostLookup = new Map(hosts.map((host) => [host.id, host]));
  const sizeMap = {};
  const assignments = {};
  const resolvedScale = normalizeScalePercent(scalePercent);

  for (const vm of plan) {
    const preservedHost = typeof currentMap?.[vm.name] === 'string' ? normalizeHostName(currentMap[vm.name]) : '';
    const host = preservedHost && hostLookup.has(preservedHost)
      ? hostLookup.get(preservedHost)
      : chooseBestHostForVm(vm, hosts);

    if (!host) {
      assignments[vm.name] = preservedHost || '';
      sizeMap[vm.name] = {
        cpu: vm.cpu,
        memory_mb: vm.memory_mb,
        disk_gb: vm.type === 'controlplane' ? CONTROLPLANE_DISK_GB : WORKER_DISK_MIN_GB,
      };
      continue;
    }

    const diskGb = vm.type === 'controlplane'
      ? CONTROLPLANE_DISK_GB
      : Math.max(
        WORKER_DISK_MIN_GB,
        Math.round(host.freeDiskGb * (resolvedScale / 100)),
      );

    sizeMap[vm.name] = {
      cpu: vm.cpu,
      memory_mb: vm.type === 'controlplane' ? CONTROLPLANE_MEMORY_MB : vm.memory_mb,
      disk_gb: diskGb,
    };

    assignments[vm.name] = host.id;
    host.freeCpuCores = Math.max(0, host.freeCpuCores - sizeMap[vm.name].cpu);
    host.freeMemoryMb = Math.max(0, host.freeMemoryMb - sizeMap[vm.name].memory_mb);
    host.freeDiskGb = Math.max(0, host.freeDiskGb - sizeMap[vm.name].disk_gb);
  }

  return {
    vmNodeMap: assignments,
    vmSizeMap: sizeMap,
  };
}

export function buildProvisionPlacementBoard(stepInputs, currentValues = {}, resources = null) {
  const vmPlan = buildProvisionVmPlan(stepInputs, currentValues);
  const hostCards = buildProvisionHostCards(resources);
  const currentMap = currentValues && typeof currentValues.vm_node_map === 'object'
    ? currentValues.vm_node_map
    : {};
  const scalePercent = currentValues?.scale_percent ?? DEFAULT_SCALE_PERCENT;
  const suggestedVmNodeMap = suggestVmNodeMap(vmPlan, hostCards, {});
  const suggestedPlacement = buildVmSizeMap(vmPlan, hostCards, suggestedVmNodeMap, scalePercent);
  const placement = buildVmSizeMap(vmPlan, hostCards, currentMap, scalePercent);
  const hostLookup = new Map(hostCards.map((host) => [host.id, host]));
  const placementsByHost = new Map(hostCards.map((host) => [host.id, []]));

  for (const vm of vmPlan) {
    const hostId = placement.vmNodeMap[vm.name];
    const selectedHostId = typeof currentMap?.[vm.name] === 'string' ? normalizeHostName(currentMap[vm.name]) : '';
    const isUserSelected = Boolean(selectedHostId) && selectedHostId === hostId && hostLookup.has(selectedHostId);
    const size = placement.vmSizeMap[vm.name] || {
      cpu: vm.cpu,
      memory_mb: vm.memory_mb,
      disk_gb: vm.disk_gb,
    };
    const entry = {
      ...vm,
      cpu: size.cpu,
      memory_mb: size.memory_mb,
      disk_gb: size.disk_gb,
      assignedHostId: hostId,
      assignedHostName: hostLookup.get(hostId)?.name || hostId || 'Unassigned',
      assignmentSource: isUserSelected ? 'user-selected' : (hostId ? 'suggested' : 'unassigned'),
      isUserSelected,
      isSuggested: !isUserSelected && Boolean(hostId),
    };

    if (!placementsByHost.has(hostId)) {
      placementsByHost.set(hostId || 'Unassigned', []);
    }
    placementsByHost.get(hostId || 'Unassigned').push(entry);
  }

  return {
    vmPlan,
    hostCards: hostCards.map((host) => ({
      ...host,
      assignments: placementsByHost.get(host.id) || [],
    })),
    unassigned: placementsByHost.get('Unassigned') || [],
    suggestedVmNodeMap,
    suggestedVmSizeMap: suggestedPlacement.vmSizeMap,
    vmNodeMap: placement.vmNodeMap,
    vmSizeMap: placement.vmSizeMap,
  };
}
