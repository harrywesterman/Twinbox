const LLM_TRACE_META = {
  ok: { label: "LLM gebruikt", tone: "is-live" },
  error: { label: "LLM fout", tone: "is-bad" },
  unconfigured: { label: "Geen LLM", tone: "is-warning" },
  pending: { label: "LLM wacht", tone: "is-neutral" },
  unavailable: { label: "Geen LLM-resultaat", tone: "is-neutral" },
};

const PENDING_LLM_WORK_ORDER_STATUSES = new Set([
  "new",
  "assigned",
  "investigating",
  "approved",
  "executing",
]);

export function buildWorkOrderLlmTrace(workOrder = {}) {
  const result = workOrder.result && typeof workOrder.result === "object" ? workOrder.result : {};
  const status =
    result.llmStatus ||
    (PENDING_LLM_WORK_ORDER_STATUSES.has(workOrder.status) ? "pending" : "unavailable");
  const meta = LLM_TRACE_META[status] || LLM_TRACE_META.unavailable;
  const summary = typeof result.llmSummary === "string" ? result.llmSummary.trim() : "";
  const model = typeof result.llmModel === "string" ? result.llmModel.trim() : "";
  const error = typeof result.llmError === "string" ? result.llmError.trim() : "";

  return {
    status,
    label: meta.label,
    tone: meta.tone,
    model,
    error,
    summary,
    hasSummary: summary.length > 0,
    usedLlm: status === "ok",
  };
}

export function buildAgentAdminViewModel(payload) {
  const agents = Array.isArray(payload.agents) ? payload.agents : [];
  const providerPayload = payload.providers || null;
  const provider =
    providerPayload?.config ||
    providerPayload?.provider ||
    (providerPayload?.baseUrl ? providerPayload : null);
  const workOrders = Array.isArray(payload.workOrders)
    ? payload.workOrders.map((workOrder) => ({
        ...workOrder,
        hasPendingApproval: workOrder?.approval?.status === "pending",
        llmTrace: buildWorkOrderLlmTrace(workOrder),
      }))
    : [];
  const events = Array.isArray(payload.events) ? payload.events : [];
  const agentTokenConfigured = !!payload.agentTokenConfigured;
  const isDegraded = payload.agents?.degraded === true || !agentTokenConfigured;
  const activeStatuses = new Set([
    "new",
    "assigned",
    "investigating",
    "proposal_ready",
    "approval_required",
    "approved",
    "executing",
    "degraded",
  ]);

  return {
    agents,
    provider,
    hasApiKey: Boolean(providerPayload?.hasApiKey),
    hasProvider: !!(provider?.baseUrl || providerPayload?.hasApiKey),
    workOrders,
    events,
    isDegraded,
    agentTokenConfigured,
    teamSummary: {
      totalAgents: agents.length,
      activeWorkOrders: workOrders.filter((workOrder) => activeStatuses.has(workOrder.status))
        .length,
    },
  };
}

export function formatAgentStatus(status) {
  if (!status) return "Unknown";
  const map = {
    online: "Online",
    offline: "Offline",
    busy: "Bezig",
    error: "Fout",
    idle: "Inactief",
  };
  return map[status.toLowerCase()] || status;
}

export function buildProviderHealthLabel(provider) {
  if (!provider) return "Niet geconfigureerd";
  const config = provider.config || provider;
  return config.displayName || config.baseUrl || "Onbekend";
}

export function groupEventsByWorkOrder(events) {
  if (!Array.isArray(events)) return {};
  const grouped = {};
  for (const event of events) {
    const key = event.workOrderId || "__general";
    if (!grouped[key]) grouped[key] = [];
    grouped[key].push(event);
  }
  return grouped;
}
