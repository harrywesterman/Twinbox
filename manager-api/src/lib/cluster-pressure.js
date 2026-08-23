const LEVELS = [
  { id: "quiet", label: "Rustig", min: 0 },
  { id: "busy", label: "Bezig", min: 60 },
  { id: "loaded", label: "Druk", min: 80 },
  { id: "very-busy", label: "Heel druk", min: 90 },
  { id: "full", label: "Vol", min: 98 },
];

function clampPercent(value) {
  const number = Number(value);
  if (!Number.isFinite(number)) return 0;
  return Math.max(0, Math.min(100, number));
}

function levelForPercent(percent) {
  const clamped = clampPercent(percent);
  return LEVELS.reduce((selected, level) => (clamped >= level.min ? level : selected), LEVELS[0]);
}

function cpuMilli(value) {
  const raw = String(value || "0").trim();
  if (!raw) return 0;
  if (raw.endsWith("m")) return Number(raw.slice(0, -1)) || 0;
  return (Number(raw) || 0) * 1000;
}

function bytes(value) {
  const raw = String(value || "0").trim();
  if (!raw) return 0;
  const units = [
    ["Ti", 1024 ** 4],
    ["Gi", 1024 ** 3],
    ["Mi", 1024 ** 2],
    ["Ki", 1024],
    ["T", 1000 ** 4],
    ["G", 1000 ** 3],
    ["M", 1000 ** 2],
    ["K", 1000],
  ];
  for (const [suffix, multiplier] of units) {
    if (raw.endsWith(suffix)) {
      return (Number(raw.slice(0, -suffix.length)) || 0) * multiplier;
    }
  }
  return Number(raw) || 0;
}

function parseTopNodes(text = "") {
  const rows = String(text || "")
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);
  const top = new Map();
  for (const row of rows) {
    if (/^NAME\s+/i.test(row)) continue;
    const parts = row.split(/\s+/);
    if (parts.length < 5) continue;
    const name = parts[0];
    top.set(name, {
      cpuPercent: Number(String(parts[2]).replace("%", "")) || 0,
      memoryPercent: Number(String(parts[4]).replace("%", "")) || 0,
    });
  }
  return top;
}

function podRequest(pod) {
  const containers = Array.isArray(pod?.spec?.containers) ? pod.spec.containers : [];
  const initContainers = Array.isArray(pod?.spec?.initContainers) ? pod.spec.initContainers : [];
  const app = containers.reduce(
    (sum, container) => {
      const requests = container?.resources?.requests || {};
      return {
        cpu: sum.cpu + cpuMilli(requests.cpu),
        memory: sum.memory + bytes(requests.memory),
      };
    },
    { cpu: 0, memory: 0 }
  );
  const init = initContainers.reduce(
    (max, container) => {
      const requests = container?.resources?.requests || {};
      return {
        cpu: Math.max(max.cpu, cpuMilli(requests.cpu)),
        memory: Math.max(max.memory, bytes(requests.memory)),
      };
    },
    { cpu: 0, memory: 0 }
  );
  return {
    cpu: Math.max(app.cpu, init.cpu),
    memory: Math.max(app.memory, init.memory),
  };
}

function summarizeNodes(nodesJson = {}, podsJson = {}, topNodesText = "") {
  const nodes = Array.isArray(nodesJson?.items) ? nodesJson.items : [];
  const pods = Array.isArray(podsJson?.items) ? podsJson.items : [];
  const top = parseTopNodes(topNodesText);
  const byNode = new Map();

  for (const node of nodes) {
    const name = String(node?.metadata?.name || "").trim();
    if (!name) continue;
    byNode.set(name, {
      name,
      cpuAllocatable: cpuMilli(node?.status?.allocatable?.cpu),
      memoryAllocatable: bytes(node?.status?.allocatable?.memory),
      cpuRequested: 0,
      memoryRequested: 0,
      podCount: 0,
      cpuActualPercent: top.get(name)?.cpuPercent || 0,
      memoryActualPercent: top.get(name)?.memoryPercent || 0,
    });
  }

  for (const pod of pods) {
    const nodeName = String(pod?.spec?.nodeName || "").trim();
    if (!nodeName || !byNode.has(nodeName)) continue;
    const request = podRequest(pod);
    const row = byNode.get(nodeName);
    row.cpuRequested += request.cpu;
    row.memoryRequested += request.memory;
    row.podCount += 1;
  }

  return Array.from(byNode.values()).map((node) => ({
    ...node,
    cpuRequestedPercent:
      node.cpuAllocatable > 0 ? (node.cpuRequested / node.cpuAllocatable) * 100 : 0,
    memoryRequestedPercent:
      node.memoryAllocatable > 0 ? (node.memoryRequested / node.memoryAllocatable) * 100 : 0,
  }));
}

function isPodReady(pod) {
  if (pod?.status?.phase === "Succeeded") return true;
  return (Array.isArray(pod?.status?.conditions) ? pod.status.conditions : []).some(
    (condition) => condition?.type === "Ready" && condition?.status === "True"
  );
}

function summarizeWorkloadNoise(podsJson = {}, eventsJson = {}) {
  const pods = Array.isArray(podsJson?.items) ? podsJson.items : [];
  const events = Array.isArray(eventsJson?.items) ? eventsJson.items : [];
  const pendingPods = pods.filter((pod) => pod?.status?.phase === "Pending").length;
  const notReadyPods = pods.filter((pod) => !isPodReady(pod)).length;
  const warningEvents = events.filter((event) => event?.type === "Warning").length;
  const percent = clampPercent(
    pendingPods * 35 + notReadyPods * 18 + Math.min(warningEvents, 20) * 3
  );
  return {
    pendingPods,
    notReadyPods,
    warningEvents,
    percent,
  };
}

function summarizeLonghorn(longhornNodesJson = {}, longhornVolumesJson = {}) {
  const nodes = Array.isArray(longhornNodesJson?.items) ? longhornNodesJson.items : [];
  const volumes = Array.isArray(longhornVolumesJson?.items) ? longhornVolumesJson.items : [];
  let maxScheduledPercent = 0;
  let unschedulableDisks = 0;

  for (const node of nodes) {
    const disks = node?.status?.diskStatus || {};
    for (const disk of Object.values(disks)) {
      const maximum = Number(disk?.storageMaximum || 0);
      const scheduled = Number(disk?.storageScheduled || 0);
      const scheduledPercent = maximum > 0 ? (scheduled / maximum) * 100 : 0;
      maxScheduledPercent = Math.max(maxScheduledPercent, scheduledPercent);
      const schedulable = (Array.isArray(disk?.conditions) ? disk.conditions : []).find(
        (condition) => condition?.type === "Schedulable"
      );
      if (schedulable && schedulable.status !== "True") {
        unschedulableDisks += 1;
      }
    }
  }

  const unhealthyVolumes = volumes.filter((volume) => {
    const robustness = String(volume?.status?.robustness || "").trim();
    return robustness && robustness !== "healthy";
  }).length;

  return {
    maxScheduledPercent,
    unschedulableDisks,
    unhealthyVolumes,
    percent: clampPercent(maxScheduledPercent + unschedulableDisks * 12 + unhealthyVolumes * 8),
  };
}

function signal(id, label, percent, detail, facts = {}) {
  const level = levelForPercent(percent);
  return {
    id,
    label,
    level: level.id,
    levelLabel: level.label,
    percent: Math.round(clampPercent(percent)),
    detail,
    ...facts,
  };
}

export function buildClusterPressureSummary({
  nodes = {},
  pods = {},
  topNodes = "",
  events = {},
  longhornNodes = {},
  longhornVolumes = {},
  generatedAt = new Date().toISOString(),
  errors = [],
} = {}) {
  const nodeRows = summarizeNodes(nodes, pods, topNodes);
  const maxCpuRequested = Math.max(0, ...nodeRows.map((node) => node.cpuRequestedPercent));
  const maxCpuActual = Math.max(0, ...nodeRows.map((node) => node.cpuActualPercent));
  const maxMemoryRequested = Math.max(0, ...nodeRows.map((node) => node.memoryRequestedPercent));
  const maxMemoryActual = Math.max(0, ...nodeRows.map((node) => node.memoryActualPercent));
  const computePercent = Math.max(maxCpuRequested, maxCpuActual);
  const memoryPercent = Math.max(maxMemoryRequested, maxMemoryActual);
  const storage = summarizeLonghorn(longhornNodes, longhornVolumes);
  const noise = summarizeWorkloadNoise(pods, events);

  const signals = [
    signal(
      "compute",
      "Rekenen",
      computePercent,
      `Hoogste worker zit op ${Math.round(maxCpuRequested)}% CPU-aanvragen en ${Math.round(maxCpuActual)}% live CPU.`,
      { requestedPercent: Math.round(maxCpuRequested), actualPercent: Math.round(maxCpuActual) }
    ),
    signal(
      "memory",
      "Geheugen",
      memoryPercent,
      `Hoogste worker zit op ${Math.round(maxMemoryRequested)}% geheugen-aanvragen en ${Math.round(maxMemoryActual)}% live geheugen.`,
      {
        requestedPercent: Math.round(maxMemoryRequested),
        actualPercent: Math.round(maxMemoryActual),
      }
    ),
    signal(
      "storage",
      "Opslag",
      storage.percent,
      `Longhorn staat maximaal op ${Math.round(storage.maxScheduledPercent)}% geplande opslag.`,
      storage
    ),
    signal(
      "noise",
      "Gedoe",
      noise.percent,
      `${noise.pendingPods} pending, ${noise.notReadyPods} niet ready, ${noise.warningEvents} warnings.`,
      noise
    ),
  ];
  const overallPercent = Math.max(0, ...signals.map((entry) => entry.percent));
  const overallLevel = levelForPercent(overallPercent);

  return {
    summary: {
      level: overallLevel.id,
      label: overallLevel.label,
      percent: Math.round(overallPercent),
      generatedAt,
      degraded: errors.length > 0,
    },
    signals,
    nodes: nodeRows.map((node) => ({
      name: node.name,
      podCount: node.podCount,
      cpuRequestedPercent: Math.round(node.cpuRequestedPercent),
      cpuActualPercent: Math.round(node.cpuActualPercent),
      memoryRequestedPercent: Math.round(node.memoryRequestedPercent),
      memoryActualPercent: Math.round(node.memoryActualPercent),
    })),
    errors,
  };
}
