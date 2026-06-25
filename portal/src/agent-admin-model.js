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
