const KNOWN_STATUSES = new Set([
  "new",
  "assigned",
  "investigating",
  "proposal_ready",
  "approval_required",
  "approved",
  "executing",
  "completed",
  "failed",
  "canceled",
  "degraded",
]);

const ACTIVE_STATUSES = new Set([
  "new",
  "assigned",
  "investigating",
  "proposal_ready",
  "approval_required",
  "approved",
  "executing",
  "degraded",
]);

const RECENT_EVENT_MS = 10 * 60 * 1000;

const WORK_TYPE_LABELS = {
  cluster_health_check: "cluster watch",
  backup_health_check: "backup patrol",
  proxmox_health_check: "hypervisor check",
  database_health_check: "database check",
  gitops_health_check: "gitops sync",
};

const STATUS_LABELS = {
  new: "queued",
  assigned: "assigned",
  investigating: "investigating",
  proposal_ready: "proposal ready",
  approval_required: "awaiting approval",
  approved: "approved",
  executing: "executing",
  completed: "wrapped up",
  failed: "needs help",
  canceled: "idle",
  degraded: "attention",
};

const MOTION_BY_STATUS = {
  new: "walking",
  assigned: "walking",
  investigating: "walking",
  proposal_ready: "typing",
  approval_required: "thinking",
  approved: "walking",
  executing: "walking",
  completed: "typing",
  failed: "alert",
  canceled: "idle",
  degraded: "alert",
};

export const IT_DEPARTMENT_AGENTS = [
  {
    id: "olivia-ops",
    displayName: "Olivia Ops",
    role: "Coordinator",
    initials: "OO",
    palette: "plum",
    x: 32,
    y: 60,
    direction: "down",
    activity: "triage loop",
    station: "ops desk",
    delay: 0,
    walkX: 22,
    walkY: -10,
  },
  {
    id: "karel-kubernetes",
    displayName: "Karel Kubernetes",
    role: "Kubernetes",
    initials: "KK",
    palette: "mint",
    x: 44,
    y: 48,
    direction: "left",
    activity: "pod watch",
    station: "cluster desk",
    delay: 0.3,
    walkX: -18,
    walkY: 16,
  },
  {
    id: "betty-backup",
    displayName: "Betty Backup",
    role: "Backups",
    initials: "BB",
    palette: "sun",
    x: 18,
    y: 33,
    direction: "right",
    activity: "snapshot shelf",
    station: "archive shelves",
    delay: 0.6,
    walkX: 20,
    walkY: 10,
  },
  {
    id: "peter-proxmox",
    displayName: "Peter Proxmox",
    role: "Proxmox",
    initials: "PP",
    palette: "coral",
    x: 58,
    y: 29,
    direction: "down",
    activity: "rack patrol",
    station: "server room",
    delay: 0.9,
    walkX: 0,
    walkY: 24,
  },
  {
    id: "tara-talos",
    displayName: "Tara Talos",
    role: "Talos",
    initials: "TT",
    palette: "sky",
    x: 30,
    y: 82,
    direction: "right",
    activity: "node boot",
    station: "console row",
    delay: 1.2,
    walkX: 28,
    walkY: 0,
  },
  {
    id: "sofia-sql",
    displayName: "Sofia SQL",
    role: "Database",
    initials: "SS",
    palette: "violet",
    x: 78,
    y: 74,
    direction: "left",
    activity: "query review",
    station: "meeting table",
    delay: 1.5,
    walkX: -20,
    walkY: -12,
  },
  {
    id: "gina-gitops",
    displayName: "Gina GitOps",
    role: "GitOps",
    initials: "GG",
    palette: "lime",
    x: 89,
    y: 58,
    direction: "left",
    activity: "sync board",
    station: "deploy nook",
    delay: 1.8,
    walkX: -24,
    walkY: 14,
  },
];

export const IT_DEPARTMENT_SCENE = {
  title: "IT department",
  eyebrow: "Pixel office",
  description:
    "The Twinbox AI beheerteam is on the floor, keeping apps, backups, and clusters moving.",
};

function asArray(value) {
  return Array.isArray(value) ? value : [];
}

function sanitizeShortText(value, fallback, maxLength = 40) {
  const normalized = String(value || "")
    .replace(/\s+/g, " ")
    .trim();
  if (!normalized) {
    return fallback;
  }
  return normalized.slice(0, maxLength);
}

function sanitizeInitials(value, fallback) {
  const normalized = String(value || "")
    .replace(/[^A-Za-z0-9]/g, "")
    .slice(0, 3)
    .toUpperCase();
  return normalized || fallback;
}

function normalizeStatus(status) {
  const normalized = String(status || "").trim();
  return KNOWN_STATUSES.has(normalized) ? normalized : "idle";
}

function getTimestampMs(value) {
  const parsed = Date.parse(value || "");
  return Number.isFinite(parsed) ? parsed : 0;
}

function getMostRelevantWorkOrder(workOrders, agentId) {
  const assigned = asArray(workOrders).filter((workOrder) =>
    asArray(workOrder?.assignedAgents).includes(agentId)
  );
  const active = assigned.filter((workOrder) =>
    ACTIVE_STATUSES.has(normalizeStatus(workOrder?.status))
  );
  const candidates = active.length > 0 ? active : assigned;
  return candidates
    .slice()
    .sort(
      (a, b) =>
        getTimestampMs(b?.updatedAt || b?.createdAt) - getTimestampMs(a?.updatedAt || a?.createdAt)
    )
    .at(0);
}

function getMostRecentEvent(events, agentId, workOrder) {
  const workOrderId = workOrder?.id;
  return asArray(events)
    .filter((event) => {
      if (event?.agentId === agentId) return true;
      if (workOrderId && event?.workOrderId === workOrderId) return true;
      return asArray(event?.metadata?.assignedAgents).includes(agentId);
    })
    .slice()
    .sort((a, b) => getTimestampMs(b?.timestamp) - getTimestampMs(a?.timestamp))
    .at(0);
}

function getActivityLabel(agent, workOrder, event, nowMs) {
  if (workOrder) {
    const typeLabel = WORK_TYPE_LABELS[workOrder.type] || "work order";
    const statusLabel = STATUS_LABELS[normalizeStatus(workOrder.status)] || "active";
    return `${typeLabel}: ${statusLabel}`;
  }

  if (event && nowMs - getTimestampMs(event.timestamp) <= RECENT_EVENT_MS) {
    if (event.severity === "error") return "checking alert";
    if (event.severity === "warning") return "reviewing warning";
    return "recent update";
  }

  return agent.activity;
}

function getMotion(workOrder, event, nowMs) {
  if (workOrder) {
    return MOTION_BY_STATUS[normalizeStatus(workOrder.status)] || "idle";
  }

  if (event && nowMs - getTimestampMs(event.timestamp) <= RECENT_EVENT_MS) {
    if (event.severity === "error" || event.severity === "warning") {
      return "alert";
    }
    return "typing";
  }

  return "idle";
}

function buildAgentProfileMap(profiles) {
  return new Map(
    asArray(profiles)
      .filter((profile) => profile?.id)
      .map((profile) => [profile.id, profile])
  );
}

export function buildItDepartmentScene(liveState = {}) {
  const profilesById = buildAgentProfileMap(liveState.agents);
  const events = asArray(liveState.events);
  const workOrders = asArray(liveState.workOrders);
  const fetchedAt = liveState.fetchedAt || new Date().toISOString();
  const nowMs = getTimestampMs(fetchedAt) || Date.now();
  const degraded = Boolean(liveState.degraded);

  const agents = IT_DEPARTMENT_AGENTS.map((agent, index) => {
    const profile = profilesById.get(agent.id);
    const workOrder = getMostRelevantWorkOrder(workOrders, agent.id);
    const event = getMostRecentEvent(events, agent.id, workOrder);
    const motion = degraded ? "alert" : getMotion(workOrder, event, nowMs);
    const status = workOrder ? normalizeStatus(workOrder.status) : event ? "recent" : "idle";

    return {
      ...agent,
      displayName: sanitizeShortText(profile?.displayName, agent.displayName),
      role: sanitizeShortText(profile?.role, agent.role),
      initials: sanitizeInitials(profile?.avatar?.initials, agent.initials),
      activity: degraded ? "agent link offline" : getActivityLabel(agent, workOrder, event, nowMs),
      status,
      focus: workOrder ? WORK_TYPE_LABELS[workOrder.type] || "work order" : "standby",
      motion,
      live: Boolean(workOrder || event),
      lastActiveAt: event?.timestamp || workOrder?.updatedAt || workOrder?.createdAt || null,
      zIndex: 20 + index,
    };
  });

  const moving = agents.filter((agent) => agent.motion !== "idle").length;
  const activeWorkOrders = workOrders.filter((workOrder) =>
    ACTIVE_STATUSES.has(normalizeStatus(workOrder?.status))
  ).length;

  return {
    ...IT_DEPARTMENT_SCENE,
    degraded,
    fetchedAt,
    liveLabel: degraded ? "offline" : moving > 0 ? "live" : "standby",
    agents,
    stats: [
      { id: "staff", label: "staff on duty", value: agents.length },
      { id: "active", label: "active motions", value: moving },
      { id: "orders", label: "active work", value: activeWorkOrders },
    ],
  };
}
