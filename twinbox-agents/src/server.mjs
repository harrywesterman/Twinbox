import express from "express";
import { listAgentProfiles, getAgentProfile } from "./agent-profiles.mjs";
import { createEventStore } from "./event-store.mjs";
import { createWorkOrderStore, VALID_TYPES } from "./work-orders.mjs";
import { createProviderConfigStore } from "./provider-config.mjs";
import { testProvider, createChatCompletion } from "./llm-client.mjs";
import { createWorkflowExecutor } from "./workflow-executor.mjs";
import {
  listUnhealthyPods,
  listRecentWarningEvents,
  summarizeNodes,
  summarizeCloudNativePgClusters,
  summarizeScheduledBackups,
  summarizeVeleroBackups,
  summarizeLonghornRecurringJobs,
} from "./k8s-readonly.mjs";
import { listArgocdApplications, listArgocdWarningEvents } from "./argo-readonly.mjs";
import { getProxmoxClusterResources, getManagerHealth } from "./manager-client.mjs";
import { postCoordinatorMessage } from "./zulip-client.mjs";

const PORT = parseInt(process.env.PORT || "8080", 10);
const DATA_DIR = process.env.AGENT_DATA_DIR || "/data";

const eventStore = createEventStore(DATA_DIR);
const workOrderStore = createWorkOrderStore(DATA_DIR);
const providerConfigStore = createProviderConfigStore(DATA_DIR);

const workflowExecutor = createWorkflowExecutor({
  eventStore,
  workOrderStore,
  getK8sUnhealthyPods: listUnhealthyPods,
  getK8sWarningEvents: listRecentWarningEvents,
  getK8sNodes: summarizeNodes,
  getK8sCnpgClusters: summarizeCloudNativePgClusters,
  getK8sScheduledBackups: summarizeScheduledBackups,
  getK8sVeleroBackups: summarizeVeleroBackups,
  getK8sLonghornJobs: summarizeLonghornRecurringJobs,
  getArgocdApps: listArgocdApplications,
  getArgocdWarnings: listArgocdWarningEvents,
  getManagerProxmox: getProxmoxClusterResources,
  getManagerHealth,
  createChatCompletion,
  getProviderConfig: () => providerConfigStore.getConfig(),
  getApiKey: () => providerConfigStore.getApiKey(),
  postCoordinatorMessage,
});

const app = express();

app.use(express.json());

function getInternalToken() {
  return process.env.TWINBOX_AGENT_INTERNAL_TOKEN;
}

function requireToken(req, res, next) {
  const token = getInternalToken();
  if (!token) {
    return res.status(503).json({
      error: "agent internal token is not configured",
    });
  }
  const authHeader = req.headers.authorization;
  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    return res.status(401).json({ error: "missing or invalid authorization" });
  }
  const provided = authHeader.slice(7);
  if (provided !== token) {
    return res.status(403).json({ error: "invalid token" });
  }
  next();
}

app.get("/api/health", (_req, res) => {
  res.json({ status: "ok", version: "1.0.0" });
});

app.get("/api/agents", requireToken, (_req, res) => {
  const profiles = listAgentProfiles();
  const sanitized = profiles.map((p) => ({
    ...p,
    systemPrompt: undefined,
  }));
  res.json(sanitized);
});

app.get("/api/events", requireToken, (req, res) => {
  const sinceId = req.query.sinceId || undefined;
  const limit = parseInt(req.query.limit || "100", 10);
  const events = eventStore.listEvents({ sinceId, limit });
  res.json(events);
});

app.get("/api/providers", requireToken, (_req, res) => {
  const config = providerConfigStore.getConfig();
  const hasApiKey = providerConfigStore.hasApiKey();
  res.json({ config, hasApiKey });
});

app.post("/api/providers/test", requireToken, async (req, res) => {
  const { baseUrl, model, apiKey } = req.body || {};
  if (!baseUrl) {
    return res.status(400).json({ error: "baseUrl is required" });
  }
  const provider = { baseUrl, model: model || "gpt-4o-mini" };
  const key = apiKey || providerConfigStore.getApiKey() || undefined;
  const result = await testProvider(provider, key);
  res.json(result);
});

app.post("/api/providers/openai-compatible", requireToken, async (req, res) => {
  const { displayName, baseUrl, model, timeoutMs, apiKey } = req.body || {};
  if (!baseUrl || !model) {
    return res.status(400).json({ error: "baseUrl and model are required" });
  }
  const config = providerConfigStore.saveConfig({
    displayName: displayName || "OpenAI Compatible",
    baseUrl,
    model,
    timeoutMs: timeoutMs || 60000,
  });
  if (apiKey) {
    providerConfigStore.saveApiKey(apiKey);
  }
  res.json({ config });
});

app.get("/api/work-orders", requireToken, (req, res) => {
  const status = req.query.status || undefined;
  const limit = parseInt(req.query.limit || "100", 10);
  const workOrders = workOrderStore.listWorkOrders({ status, limit });
  res.json(workOrders);
});

app.post("/api/work-orders", requireToken, async (req, res) => {
  const { type, title, scope } = req.body || {};
  if (!type || !title) {
    return res.status(400).json({ error: "type and title are required" });
  }

  if (!VALID_TYPES.includes(type)) {
    return res.status(400).json({ error: `unknown work order type: ${type}` });
  }

  const agents = findAgentsForType(type);
  const agentProfiles = agents.map((id) => getAgentProfile(id)).filter(Boolean);

  const workOrder = workOrderStore.createWorkOrder({
    type,
    title,
    scope: scope || null,
    createdBy: "api",
    assignedAgents: agentProfiles.map((a) => a.id),
  });

  eventStore.appendEvent({
    agentId: "system",
    workOrderId: workOrder.id,
    type: "status",
    severity: "info",
    title: "Work order created",
    message: `Work order ${workOrder.id} created for ${type}: ${title}`,
    metadata: { type, workOrderId: workOrder.id, assignedAgents: agents },
  });

  workOrderStore.updateWorkOrder(workOrder.id, { status: "investigating" });

  let executed;
  try {
    executed = await workflowExecutor.executeWorkOrder(workOrder);
  } catch (err) {
    workOrderStore.updateWorkOrder(workOrder.id, {
      status: "failed",
      result: { error: err.message },
    });
    eventStore.appendEvent({
      agentId: "system",
      workOrderId: workOrder.id,
      type: "error",
      severity: "error",
      title: "Execution failed",
      message: err.message,
    });
    executed = workOrderStore.getWorkOrder(workOrder.id);
  }

  res.status(201).json(executed);
});

app.get("/api/work-orders/:id", requireToken, (req, res) => {
  const wo = workOrderStore.getWorkOrder(req.params.id);
  if (!wo) {
    return res.status(404).json({ error: "work order not found" });
  }
  res.json(wo);
});

app.post("/api/work-orders/:id/approve", requireToken, async (req, res) => {
  const { approver } = req.body || {};
  if (!approver) {
    return res.status(400).json({ error: "approver is required" });
  }
  const updated = workOrderStore.approveWorkOrder(req.params.id, approver);
  if (!updated) {
    return res.status(404).json({ error: "work order not found or no pending approval" });
  }
  eventStore.appendEvent({
    agentId: "system",
    workOrderId: updated.id,
    type: "status",
    severity: "info",
    title: "Work order approved",
    message: `Work order ${updated.id} approved by ${approver}`,
  });
  res.json(updated);
});

app.post("/api/work-orders/:id/cancel", requireToken, async (req, res) => {
  const { actor } = req.body || {};
  if (!actor) {
    return res.status(400).json({ error: "actor is required" });
  }
  const updated = workOrderStore.cancelWorkOrder(req.params.id, actor);
  if (!updated) {
    return res.status(404).json({ error: "work order not found" });
  }
  eventStore.appendEvent({
    agentId: "system",
    workOrderId: updated.id,
    type: "status",
    severity: "warning",
    title: "Work order canceled",
    message: `Work order ${updated.id} canceled by ${actor}`,
  });
  res.json(updated);
});

function findAgentsForType(type) {
  const specialists = {
    cluster_health_check: ["olivia-ops", "karel-kubernetes"],
    backup_health_check: ["olivia-ops", "betty-backup"],
    proxmox_health_check: ["olivia-ops", "peter-proxmox"],
    database_health_check: ["olivia-ops", "sofia-sql"],
    gitops_health_check: ["olivia-ops", "gina-gitops"],
  };
  return specialists[type] || ["olivia-ops"];
}

const startedServer = !process.env.PORT || process.env.PORT !== "0" ? app.listen(PORT) : null;

export { app, startedServer };
