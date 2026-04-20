const MB_PER_GB = 1024;
const MIN_SCALE_PERCENT = 0;
const DEFAULT_SCALE_PERCENT = 90;
const MAX_SCALE_PERCENT = 100;
const MAX_FOOTPRINT_MULTIPLIER = 4;
const MIN_WORKER_DISK_PERCENT = 10;
const DEFAULT_WORKER_DISK_PERCENT = 80;
const MAX_WORKER_DISK_PERCENT = 100;

const CONTROLPLANE_MEMORY_MB = 4096;
const CONTROLPLANE_DISK_GB = 10;
const WORKER_DISK_MIN_GB = 10;
const WORKER_DISK_FALLBACK_GB = 100;
const WORKER_PLACEMENT_DISK_GB = 10;
const WORKER_MEMORY_DEFAULT_MB = 10240;

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

function normalizeWorkerDiskPercent(value) {
  return clamp(
    roundToInteger(toNumber(value, DEFAULT_WORKER_DISK_PERCENT)),
    MIN_WORKER_DISK_PERCENT,
    MAX_WORKER_DISK_PERCENT,
  );
}

function normalizeHostName(value) {
  return String(value || '').trim();
}

function getVmResourceNumber(value, divisor) {
  const resolved = toNumber(value, 0);
  return resolved > 0 ? resolved / divisor : 0;
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
  const controlplaneCount = Math.max(1, roundToInteger(getInputDefault(stepInputs, 'controlplane_count', 3)));
  const workerCount = Math.max(0, roundToInteger(getInputDefault(stepInputs, 'worker_count', 3)));
  const nodeCount = Math.max(1, controlplaneCount + workerCount);
  const cpuCores = Math.max(1, roundToInteger(getInputDefault(stepInputs, 'cpu_cores', 2)));
  const workerMemoryMb = Math.max(512, roundToStep(getInputDefault(stepInputs, 'memory_mb', WORKER_MEMORY_DEFAULT_MB), 512));
  const scalePercent = normalizeScalePercent(getInputDefault(stepInputs, 'scale_percent', DEFAULT_SCALE_PERCENT));
  const workerDiskPercent = normalizeWorkerDiskPercent(getInputDefault(stepInputs, 'worker_disk_percent', DEFAULT_WORKER_DISK_PERCENT));

  return {
    scalePercent,
    workerDiskPercent,
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
      worker_disk_percent: getInputBounds(stepInputs, 'worker_disk_percent', { min: MIN_WORKER_DISK_PERCENT, max: MAX_WORKER_DISK_PERCENT }),
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

function deriveWorkerDiskGb(hostCards, workerCount, workerDiskPercent = DEFAULT_WORKER_DISK_PERCENT, fallbackGb = WORKER_DISK_FALLBACK_GB) {
  const hosts = Array.isArray(hostCards) ? hostCards : [];
  const resolvedPercent = normalizeWorkerDiskPercent(workerDiskPercent);
  const freeDiskShares = hosts
    .map((host) => Math.max(0, toNumber(host.freeDiskGb, 0)))
    .filter((value) => value > 0);

  if (freeDiskShares.length === 0 || workerCount <= 0) {
    return fallbackGb;
  }

  return Math.max(
    WORKER_DISK_MIN_GB,
    Math.floor(Math.min(...freeDiskShares) * (resolvedPercent / 100)),
  );
}

function getPlacementVmSize(vm, workerDiskGb = WORKER_DISK_FALLBACK_GB) {
  if (vm.type === 'controlplane') {
    return {
      cpu: vm.cpu,
      memory_mb: CONTROLPLANE_MEMORY_MB,
      disk_gb: CONTROLPLANE_DISK_GB,
    };
  }

  return {
    cpu: vm.cpu,
    memory_mb: vm.memory_mb,
    disk_gb: Math.max(WORKER_DISK_MIN_GB, roundToInteger(toNumber(workerDiskGb, WORKER_DISK_FALLBACK_GB))),
  };
}

function getPreferredHostIndex(vm, hostCount) {
  const name = normalizeHostName(vm?.name || vm?.id);
  const match = name.match(/^(?:cp|worker)-(\d+)$/i);
  if (!match) {
    return 0;
  }

  const parsed = Math.max(1, roundToInteger(toNumber(match[1], 1))) - 1;
  if (hostCount <= 0) {
    return 0;
  }

  return clamp(parsed, 0, hostCount - 1);
}

function getOrderedHostsForVm(vm, hostCards) {
  const hosts = Array.isArray(hostCards) ? hostCards : [];
  if (hosts.length <= 1) {
    return hosts;
  }

  const preferredIndex = getPreferredHostIndex(vm, hosts.length);
  return [
    ...hosts.slice(preferredIndex),
    ...hosts.slice(0, preferredIndex),
  ];
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
    worker_disk_percent: Number.isFinite(Number(existing.worker_disk_percent))
      ? normalizeWorkerDiskPercent(existing.worker_disk_percent)
      : baseline.workerDiskPercent,
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
  const resolvedWorkerDiskPercent = normalizeWorkerDiskPercent(currentValues.worker_disk_percent ?? baseline.workerDiskPercent);
  const resourceSummary = resources?.summary || null;
  const controlplaneCount = Math.max(1, roundToInteger(toNumber(currentValues.controlplane_count, baseline.controlplaneCount)));
  const workerCount = Math.max(0, roundToInteger(toNumber(currentValues.worker_count, baseline.workerCount)));
  const cpuCores = Math.max(1, roundToInteger(toNumber(currentValues.cpu_cores, baseline.cpuCores)));
  const workerMemoryMb = Math.max(512, roundToStep(toNumber(currentValues.memory_mb, baseline.workerMemoryMb), 512));
  const totalNodes = Math.max(1, controlplaneCount + workerCount);
  const placementBoard = buildProvisionPlacementBoard(stepInputs, currentValues, resources);
  const hasCurrentPlacement = currentValues?.vm_node_map
    && typeof currentValues.vm_node_map === 'object'
    && Object.values(currentValues.vm_node_map).some((value) => String(value || '').trim().length > 0);
  const sizeMap = hasCurrentPlacement ? placementBoard.vmSizeMap : placementBoard.suggestedVmSizeMap;
  const summaryFallbackWorkerDiskGb = resourceSummary?.freeDiskGb > 0 && workerCount > 0
    ? Math.max(
      WORKER_DISK_MIN_GB,
      Math.floor((resourceSummary.freeDiskGb / Math.max(1, workerCount)) * (resolvedWorkerDiskPercent / 100)),
    )
    : WORKER_DISK_FALLBACK_GB;
  const workerDiskPerVm = placementBoard.hostCards.length > 0
    ? sizeMap?.['worker-1']?.disk_gb
      ?? placementBoard.suggestedVmSizeMap?.['worker-1']?.disk_gb
      ?? summaryFallbackWorkerDiskGb
    : summaryFallbackWorkerDiskGb;

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
    worker_disk_percent: resolvedWorkerDiskPercent,
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

function buildManagementVmResource(vmResources, hostLookup) {
  if (!Array.isArray(vmResources) || !hostLookup) {
    return null;
  }

  const resource = vmResources.find((entry) => {
    const name = normalizeHostName(entry?.name || entry?.vm_name || entry?.id);
    const tags = String(entry?.tags || '').toLowerCase();
    return tags.includes('management') || name.endsWith('-mgt') || name.endsWith('mgt');
  });

  if (!resource) {
    return null;
  }

  const node = normalizeHostName(resource?.node || resource?.statusnode || '');
  const host = hostLookup.get(node) || null;
  const memoryMb = getVmResourceNumber(resource?.maxmem || resource?.mem, 1024 * 1024);
  const diskGb = getVmResourceNumber(resource?.maxdisk || resource?.disk, 1024 * 1024 * 1024);

  return {
    id: `management-${normalizeHostName(resource?.name || resource?.vm_name || resource?.vmid || 'vm')}`,
    name: normalizeHostName(resource?.name || resource?.vm_name || resource?.id || 'Twinbox management VM'),
    label: 'Management VM',
    type: 'management',
    vmid: resource?.vmid ?? null,
    hostId: node,
    hostName: host?.name || node,
    cpu: Math.max(0, roundToInteger(toNumber(resource?.maxcpu, 0))),
    memory_mb: memoryMb > 0 ? memoryMb : null,
    disk_gb: diskGb > 0 ? diskGb : null,
    status: String(resource?.status || resource?.qmpstatus || 'unknown'),
    assignmentSource: 'fixed',
    isFixed: true,
    isSuggested: false,
    isUserSelected: false,
  };
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

function compareVmPlacementState(leftState, rightState, vmType) {
  if (vmType === 'controlplane') {
    if (leftState.controlplaneCount !== rightState.controlplaneCount) {
      return leftState.controlplaneCount - rightState.controlplaneCount;
    }
  } else if (vmType === 'worker') {
    if (leftState.workerCount !== rightState.workerCount) {
      return leftState.workerCount - rightState.workerCount;
    }
  }

  if (leftState.totalCount !== rightState.totalCount) {
    return leftState.totalCount - rightState.totalCount;
  }

  return 0;
}

function clonePlacementState(sourceState = new Map()) {
  const nextState = new Map();
  for (const [hostId, state] of sourceState.entries()) {
    nextState.set(hostId, {
      controlplaneCount: state?.controlplaneCount || 0,
      workerCount: state?.workerCount || 0,
      totalCount: state?.totalCount || 0,
    });
  }
  return nextState;
}

function hostCanFitVm(host, vm) {
  return Math.max(0, toNumber(host?.freeDiskGb, 0)) >= Math.max(0, toNumber(vm?.disk_gb, 0));
}

function compareHostCapacity(leftHost, rightHost) {
  if (leftHost.totalMemoryMb !== rightHost.totalMemoryMb) {
    return rightHost.totalMemoryMb - leftHost.totalMemoryMb;
  }

  if (leftHost.totalDiskGb !== rightHost.totalDiskGb) {
    return rightHost.totalDiskGb - leftHost.totalDiskGb;
  }

  if (leftHost.totalCpuCores !== rightHost.totalCpuCores) {
    return rightHost.totalCpuCores - leftHost.totalCpuCores;
  }

  if (leftHost.freeMemoryMb !== rightHost.freeMemoryMb) {
    return leftHost.freeMemoryMb - rightHost.freeMemoryMb;
  }

  if (leftHost.freeDiskGb !== rightHost.freeDiskGb) {
    return leftHost.freeDiskGb - rightHost.freeDiskGb;
  }

  if (leftHost.freeCpuCores !== rightHost.freeCpuCores) {
    return leftHost.freeCpuCores - rightHost.freeCpuCores;
  }

  if (leftHost.activeVmCount !== rightHost.activeVmCount) {
    return leftHost.activeVmCount - rightHost.activeVmCount;
  }

  return 0;
}

function compareHostCandidates(leftHost, rightHost, vm, placementState, resolveVmSize = null) {
  const leftState = placementState.get(leftHost.id) || {
    controlplaneCount: 0,
    workerCount: 0,
    totalCount: 0,
  };
  const rightState = placementState.get(rightHost.id) || {
    controlplaneCount: 0,
    workerCount: 0,
    totalCount: 0,
  };

  const leftVm = typeof resolveVmSize === 'function' ? resolveVmSize(vm, leftHost) : vm;
  const rightVm = typeof resolveVmSize === 'function' ? resolveVmSize(vm, rightHost) : vm;
  const leftFits = hostCanFitVm(leftHost, leftVm);
  const rightFits = hostCanFitVm(rightHost, rightVm);
  if (leftFits !== rightFits) {
    return leftFits ? -1 : 1;
  }

  const occupancyComparison = compareVmPlacementState(leftState, rightState, vm.type);
  if (occupancyComparison !== 0) {
    return occupancyComparison;
  }

  const capacityComparison = compareHostCapacity(leftHost, rightHost);
  if (capacityComparison !== 0) {
    return capacityComparison;
  }

  return normalizeHostName(leftHost?.name || leftHost?.id).localeCompare(
    normalizeHostName(rightHost?.name || rightHost?.id),
    undefined,
    { sensitivity: 'base' },
  );
}

function chooseBestHostForVm(vm, hostCards, placementState = new Map(), resolveVmSize = null) {
  const orderedHosts = getOrderedHostsForVm(vm, hostCards);
  for (const host of orderedHosts) {
    const candidateVm = typeof resolveVmSize === 'function' ? resolveVmSize(vm, host) : vm;
    if (hostCanFitVm(host, candidateVm)) {
      return host;
    }
  }
  return null;
}

export function suggestVmNodeMap(
  vmPlan,
  hostCards,
  currentMap = {},
  placementState = new Map(),
  workerDiskPercent = DEFAULT_WORKER_DISK_PERCENT,
  fallbackWorkerDiskGb = WORKER_DISK_FALLBACK_GB,
) {
  const plan = Array.isArray(vmPlan) ? vmPlan : [];
  const hosts = Array.isArray(hostCards) ? hostCards.map((host) => ({ ...host })) : [];
  const assignments = {};
  const hostLookup = new Map(hosts.map((host) => [host.id, host]));
  const resolveVmSize = (vm) => getPlacementVmSize(vm, fallbackWorkerDiskGb);

  for (const vm of plan) {
    const preservedHost = typeof currentMap?.[vm.name] === 'string' ? normalizeHostName(currentMap[vm.name]) : '';
    const host = preservedHost && hostLookup.has(preservedHost)
      ? hostLookup.get(preservedHost)
      : chooseBestHostForVm(vm, hosts, placementState, resolveVmSize);

    if (!host) {
      assignments[vm.name] = preservedHost || '';
      continue;
    }

    assignments[vm.name] = host.id;
    const resolvedVm = resolveVmSize(vm, host);
    const state = placementState.get(host.id);
    if (state) {
      state.totalCount += 1;
      if (vm.type === 'controlplane') {
        state.controlplaneCount += 1;
      } else if (vm.type === 'worker') {
        state.workerCount += 1;
      }
    }

    host.freeCpuCores = Math.max(0, host.freeCpuCores - resolvedVm.cpu);
    host.freeMemoryMb = Math.max(0, host.freeMemoryMb - resolvedVm.memory_mb);
    host.freeDiskGb = Math.max(0, host.freeDiskGb - resolvedVm.disk_gb);
  }

  return assignments;
}

function buildVmSizeMap(vmPlan, hostCards, currentMap = {}, workerDiskPercent = DEFAULT_WORKER_DISK_PERCENT, allowSuggestedPlacement = true, placementState = new Map(), placementWorkerDiskGb = WORKER_PLACEMENT_DISK_GB) {
  const plan = Array.isArray(vmPlan) ? vmPlan : [];
  const workingHosts = Array.isArray(hostCards) ? hostCards.map((host) => ({ ...host })) : [];
  const hostLookup = new Map(workingHosts.map((host) => [host.id, host]));
  const sizeMap = {};
  const assignments = {};
  const resolvedWorkerDiskGb = Math.max(
    WORKER_DISK_MIN_GB,
    roundToInteger(toNumber(placementWorkerDiskGb, WORKER_PLACEMENT_DISK_GB)),
  );
  const resolveVmSize = (vm) => getPlacementVmSize(vm, resolvedWorkerDiskGb);

  for (const vm of plan) {
    const preservedHost = typeof currentMap?.[vm.name] === 'string' ? normalizeHostName(currentMap[vm.name]) : '';
    const host = preservedHost && hostLookup.has(preservedHost)
      ? hostLookup.get(preservedHost)
      : allowSuggestedPlacement
        ? chooseBestHostForVm(vm, workingHosts, placementState, resolveVmSize)
        : null;
    const resolvedSize = resolveVmSize(vm, host || null);

    if (!host) {
      sizeMap[vm.name] = resolvedSize;
      continue;
    }

    sizeMap[vm.name] = resolvedSize;

    assignments[vm.name] = host.id;
    const state = placementState.get(host.id);
    if (state) {
      state.totalCount += 1;
      if (vm.type === 'controlplane') {
        state.controlplaneCount += 1;
      } else if (vm.type === 'worker') {
        state.workerCount += 1;
      }
    }

    host.freeCpuCores = Math.max(0, host.freeCpuCores - resolvedSize.cpu);
    host.freeMemoryMb = Math.max(0, host.freeMemoryMb - resolvedSize.memory_mb);
    host.freeDiskGb = Math.max(0, host.freeDiskGb - resolvedSize.disk_gb);
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
  const workerDiskPercent = currentValues?.worker_disk_percent ?? DEFAULT_WORKER_DISK_PERCENT;
  const suggestedWorkerDiskGb = deriveWorkerDiskGb(hostCards, vmPlan.filter((vm) => vm.type === 'worker').length, workerDiskPercent);
  const hostLookup = new Map(hostCards.map((host) => [host.id, host]));
  const placementsByHost = new Map(hostCards.map((host) => [host.id, []]));
  const managementVm = buildManagementVmResource(resources?.vms, hostLookup);
  const basePlacementState = new Map(hostCards.map((host) => [host.id, {
    controlplaneCount: 0,
    workerCount: 0,
    totalCount: 0,
  }]));

  if (managementVm?.hostId && basePlacementState.has(managementVm.hostId)) {
    const state = basePlacementState.get(managementVm.hostId);
    state.totalCount += 1;
    const fixedEntry = {
      ...managementVm,
      assignedHostId: managementVm.hostId,
      assignedHostName: managementVm.hostName || managementVm.hostId,
    };
    placementsByHost.get(managementVm.hostId).push(fixedEntry);
  }

  const suggestedPlacementState = clonePlacementState(basePlacementState);
  const currentPlacementState = clonePlacementState(basePlacementState);
  const suggestedVmNodeMap = suggestVmNodeMap(vmPlan, hostCards, {}, suggestedPlacementState, workerDiskPercent, suggestedWorkerDiskGb);
  const suggestedPlacement = buildVmSizeMap(
    vmPlan,
    hostCards,
    suggestedVmNodeMap,
    workerDiskPercent,
    true,
    clonePlacementState(basePlacementState),
    suggestedWorkerDiskGb,
  );
  const placement = buildVmSizeMap(
    vmPlan,
    hostCards,
    currentMap,
    workerDiskPercent,
    false,
    currentPlacementState,
    suggestedWorkerDiskGb,
  );

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

    const bucketId = hostId || 'Unassigned';
    if (!placementsByHost.has(bucketId)) {
      placementsByHost.set(bucketId, []);
    }
    placementsByHost.get(bucketId).push(entry);
  }

  return {
    vmPlan,
    managementVm,
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

function countAssignedPlacementEntries(vmNodeMap = {}) {
  return Object.values(vmNodeMap || {}).reduce((count, hostName) => (
    String(hostName || '').trim().length > 0 ? count + 1 : count
  ), 0);
}

function formatAutomaticPlacementMessage(assigned, total) {
  if (total <= 0) {
    return {
      tone: 'danger',
      message: 'No Talos VMs are defined for automatic placement.',
    };
  }

  if (assigned <= 0) {
    return {
      tone: 'danger',
      message: 'Automatic placement could not place any Talos VMs with the current free CPU, memory, and disk.',
    };
  }

  if (assigned >= total) {
    return {
      tone: 'success',
      message: `Automatic placement assigned all ${total} Talos VMs.`,
    };
  }

  const unassigned = total - assigned;
  return {
    tone: 'warning',
    message: `Automatic placement assigned ${assigned} of ${total} Talos VMs. ${unassigned} remain unassigned because current free CPU, memory, or disk is insufficient.`,
  };
}

export function buildAutomaticProvisionPlacementResult(stepInputs, currentValues = {}, resources = null) {
  const normalizedDraft = currentValues && typeof currentValues === 'object' ? currentValues : {};
  const board = buildProvisionPlacementBoard(stepInputs, normalizedDraft, resources);
  const vmNodeMap = board.suggestedVmNodeMap || {};
  const vmSizeMap = board.suggestedVmSizeMap || {};
  const total = Array.isArray(board.vmPlan) ? board.vmPlan.filter((vm) => vm.type !== 'management').length : 0;
  const assigned = countAssignedPlacementEntries(vmNodeMap);
  const unassigned = Math.max(0, total - assigned);
  const placementMessage = formatAutomaticPlacementMessage(assigned, total);

  return {
    board,
    vm_node_map: vmNodeMap,
    vm_size_map: vmSizeMap,
    assigned,
    unassigned,
    tone: placementMessage.tone,
    message: placementMessage.message,
  };
}
