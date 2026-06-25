import test from "node:test";
import assert from "node:assert/strict";
import os from "node:os";
import path from "node:path";
import fs from "node:fs";
import { createEventStore } from "../src/event-store.mjs";
import { createWorkOrderStore } from "../src/work-orders.mjs";
import { createWorkflowExecutor } from "../src/workflow-executor.mjs";

function tempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "wf-exec-test-"));
}

function makeWorkOrder(dataDir, overrides = {}) {
  const store = createWorkOrderStore(dataDir);
  return store.createWorkOrder({
    type: overrides.type || "cluster_health_check",
    title: overrides.title || "Test work order",
    createdBy: "test",
    scope: overrides.scope || null,
    assignedAgents: overrides.assignedAgents || ["olivia-ops", "karel-kubernetes"],
  });
}

test("executor handles cluster_health_check with degraded k8s", async () => {
  const dataDir = tempDir();
  const eventStore = createEventStore(dataDir);
  const workOrderStore = createWorkOrderStore(dataDir);
  const wo = makeWorkOrder(dataDir, { type: "cluster_health_check" });

  const executor = createWorkflowExecutor({
    eventStore,
    workOrderStore,
    getK8sUnhealthyPods: async () => ({ error: "no k8s", available: false }),
    getK8sWarningEvents: async () => ({ error: "no k8s", available: false }),
    getK8sNodes: async () => ({ error: "no k8s", available: false }),
    getK8sCnpgClusters: async () => ({ error: "no k8s", available: false }),
    getK8sScheduledBackups: async () => ({ error: "no k8s", available: false }),
    getK8sVeleroBackups: async () => ({ error: "no k8s", available: false }),
    getK8sLonghornJobs: async () => ({ error: "no k8s", available: false }),
    getArgocdApps: async () => ({ error: "no k8s", available: false }),
    getArgocdWarnings: async () => ({ error: "no k8s", available: false }),
    getManagerProxmox: async () => ({ error: "no mgmt", available: false }),
    getManagerHealth: async () => ({ error: "no mgmt", available: false }),
    createChatCompletion: async () => {
      throw new Error("should not be called");
    },
    getProviderConfig: () => null,
    getApiKey: () => null,
  });

  const result = await executor.executeWorkOrder(wo);
  assert.ok(result);
  assert.equal(result.status, "degraded");
  assert.ok(result.evidence);
  assert.ok(result.evidence.length > 0);
  assert.ok(result.result.facts);
  assert.equal(result.result.llmStatus, "unconfigured");

  const events = eventStore.listEvents({});
  assert.ok(events.length > 0);
  assert.ok(events.some((e) => e.title.includes("gestart") || e.title.includes("started")));
});

test("executor handles backup_health_check", async () => {
  const dataDir = tempDir();
  const eventStore = createEventStore(dataDir);
  const workOrderStore = createWorkOrderStore(dataDir);
  const wo = makeWorkOrder(dataDir, { type: "backup_health_check" });

  const executor = createWorkflowExecutor({
    eventStore,
    workOrderStore,
    getK8sUnhealthyPods: async () => [],
    getK8sWarningEvents: async () => [],
    getK8sNodes: async () => [],
    getK8sCnpgClusters: async () => [],
    getK8sScheduledBackups: async () => [],
    getK8sVeleroBackups: async () => [],
    getK8sLonghornJobs: async () => [],
    getArgocdApps: async () => [],
    getArgocdWarnings: async () => [],
    getManagerProxmox: async () => [],
    getManagerHealth: async () => ({ status: "ok" }),
    createChatCompletion: async () => {
      throw new Error("should not be called");
    },
    getProviderConfig: () => null,
    getApiKey: () => null,
  });

  const result = await executor.executeWorkOrder(wo);
  assert.ok(result);
  assert.equal(result.status, "proposal_ready");
  assert.ok(result.result.facts);
  assert.ok("veleroBackups" in result.result.facts);
  assert.ok("longhornRecurringJobs" in result.result.facts);
  assert.ok("cnpgScheduledBackups" in result.result.facts);
});

test("executor handles proxmox_health_check", async () => {
  const dataDir = tempDir();
  const eventStore = createEventStore(dataDir);
  const workOrderStore = createWorkOrderStore(dataDir);
  const wo = makeWorkOrder(dataDir, { type: "proxmox_health_check" });

  const executor = createWorkflowExecutor({
    eventStore,
    workOrderStore,
    getK8sUnhealthyPods: async () => [],
    getK8sWarningEvents: async () => [],
    getK8sNodes: async () => [],
    getK8sCnpgClusters: async () => [],
    getK8sScheduledBackups: async () => [],
    getK8sVeleroBackups: async () => [],
    getK8sLonghornJobs: async () => [],
    getArgocdApps: async () => [],
    getArgocdWarnings: async () => [],
    getManagerProxmox: async () => ({
      cluster: "proxmox-cluster",
      nodes: [{ name: "pve1", status: "online" }],
    }),
    getManagerHealth: async () => ({ status: "ok" }),
    createChatCompletion: async () => {
      throw new Error("should not be called");
    },
    getProviderConfig: () => null,
    getApiKey: () => null,
  });

  const result = await executor.executeWorkOrder(wo);
  assert.ok(result);
  assert.equal(result.status, "proposal_ready");
  assert.ok(result.result.facts.proxmoxResources);
  assert.equal(result.result.facts.proxmoxResources.cluster, "proxmox-cluster");
});

test("executor handles database_health_check", async () => {
  const dataDir = tempDir();
  const eventStore = createEventStore(dataDir);
  const workOrderStore = createWorkOrderStore(dataDir);
  const wo = makeWorkOrder(dataDir, { type: "database_health_check" });

  const executor = createWorkflowExecutor({
    eventStore,
    workOrderStore,
    getK8sUnhealthyPods: async () => [],
    getK8sWarningEvents: async () => [],
    getK8sNodes: async () => [],
    getK8sCnpgClusters: async () => [
      {
        name: "main-db",
        namespace: "default",
        status: "Cluster in healthy state",
        instances: 3,
        readyInstances: 3,
      },
    ],
    getK8sScheduledBackups: async () => [
      { name: "daily-backup", schedule: "0 2 * * *", cluster: "main-db" },
    ],
    getK8sVeleroBackups: async () => [],
    getK8sLonghornJobs: async () => [],
    getArgocdApps: async () => [],
    getArgocdWarnings: async () => [],
    getManagerProxmox: async () => [],
    getManagerHealth: async () => ({ status: "ok" }),
    createChatCompletion: async () => {
      throw new Error("should not be called");
    },
    getProviderConfig: () => null,
    getApiKey: () => null,
  });

  const result = await executor.executeWorkOrder(wo);
  assert.ok(result);
  assert.equal(result.status, "proposal_ready");
  assert.ok(result.result.facts.cnpgClusters);
  assert.ok(result.result.facts.cnpgScheduledBackups);
  assert.equal(result.result.facts.cnpgClusters[0].name, "main-db");
});

test("executor keeps database health degraded when facts are unavailable but LLM responds", async () => {
  const dataDir = tempDir();
  const eventStore = createEventStore(dataDir);
  const workOrderStore = createWorkOrderStore(dataDir);
  const wo = makeWorkOrder(dataDir, { type: "database_health_check" });

  const executor = createWorkflowExecutor({
    eventStore,
    workOrderStore,
    getK8sUnhealthyPods: async () => [],
    getK8sWarningEvents: async () => [],
    getK8sNodes: async () => [],
    getK8sCnpgClusters: async () => {
      throw new Error("CNPG list response missing items");
    },
    getK8sScheduledBackups: async () => [{ name: "daily-backup", cluster: "main-db" }],
    getK8sVeleroBackups: async () => [],
    getK8sLonghornJobs: async () => [],
    getArgocdApps: async () => [],
    getArgocdWarnings: async () => [],
    getManagerProxmox: async () => [],
    getManagerHealth: async () => ({ status: "ok" }),
    createChatCompletion: async () => ({
      choices: [{ message: { content: "CNPG brondata is gedeeltelijk onbeschikbaar." } }],
      model: "test-model",
    }),
    getProviderConfig: () => ({ baseUrl: "http://test/v1", model: "test-model" }),
    getApiKey: () => null,
  });

  const result = await executor.executeWorkOrder(wo);
  assert.equal(result.status, "degraded");
  assert.equal(result.result.llmStatus, "ok");
  assert.equal(result.result.facts.cnpgClusters.available, false);

  const events = eventStore.listEvents({});
  assert.ok(events.some((event) => event.title === "Onderzoek afgerond met aandachtspunten"));
});

test("executor handles gitops_health_check", async () => {
  const dataDir = tempDir();
  const eventStore = createEventStore(dataDir);
  const workOrderStore = createWorkOrderStore(dataDir);
  const wo = makeWorkOrder(dataDir, { type: "gitops_health_check" });

  const executor = createWorkflowExecutor({
    eventStore,
    workOrderStore,
    getK8sUnhealthyPods: async () => [],
    getK8sWarningEvents: async () => [],
    getK8sNodes: async () => [],
    getK8sCnpgClusters: async () => [],
    getK8sScheduledBackups: async () => [],
    getK8sVeleroBackups: async () => [],
    getK8sLonghornJobs: async () => [],
    getArgocdApps: async () => [
      { name: "twinbox-portal", syncStatus: "Synced", healthStatus: "Healthy" },
    ],
    getArgocdWarnings: async () => [],
    getManagerProxmox: async () => [],
    getManagerHealth: async () => ({ status: "ok" }),
    createChatCompletion: async () => {
      throw new Error("should not be called");
    },
    getProviderConfig: () => null,
    getApiKey: () => null,
  });

  const result = await executor.executeWorkOrder(wo);
  assert.ok(result);
  assert.equal(result.status, "proposal_ready");
  assert.ok(result.result.facts.argocdApplications);
  assert.equal(result.result.facts.argocdApplications[0].name, "twinbox-portal");
});

test("executor generates LLM summary when configured", async () => {
  const dataDir = tempDir();
  const eventStore = createEventStore(dataDir);
  const workOrderStore = createWorkOrderStore(dataDir);
  const wo = makeWorkOrder(dataDir, { type: "cluster_health_check" });

  const executor = createWorkflowExecutor({
    eventStore,
    workOrderStore,
    getK8sUnhealthyPods: async () => [],
    getK8sWarningEvents: async () => [],
    getK8sNodes: async () => [{ name: "node-1", ready: true }],
    getK8sCnpgClusters: async () => [],
    getK8sScheduledBackups: async () => [],
    getK8sVeleroBackups: async () => [],
    getK8sLonghornJobs: async () => [],
    getArgocdApps: async () => [],
    getArgocdWarnings: async () => [],
    getManagerProxmox: async () => [],
    getManagerHealth: async () => ({ status: "ok" }),
    createChatCompletion: async (_provider, _apiKey, _messages) => ({
      choices: [{ message: { content: "De cluster is gezond. Alle nodes zijn ready." } }],
      model: "test-model",
    }),
    getProviderConfig: () => ({ baseUrl: "http://test/v1", model: "test-model" }),
    getApiKey: () => "test-key",
  });

  const result = await executor.executeWorkOrder(wo);
  assert.ok(result);
  assert.equal(result.status, "proposal_ready");
  assert.equal(result.result.llmStatus, "ok");
  assert.equal(result.result.llmModel, "test-model");
  assert.ok(result.result.llmSummary);
  assert.ok(result.result.llmSummary.includes("gezond"));
});

test("executor uses configured local endpoint without API key", async () => {
  const dataDir = tempDir();
  const eventStore = createEventStore(dataDir);
  const workOrderStore = createWorkOrderStore(dataDir);
  const wo = makeWorkOrder(dataDir, { type: "cluster_health_check" });
  let observedApiKey = "not-called";

  const executor = createWorkflowExecutor({
    eventStore,
    workOrderStore,
    getK8sUnhealthyPods: async () => [],
    getK8sWarningEvents: async () => [],
    getK8sNodes: async () => [{ name: "node-1", ready: true }],
    getK8sCnpgClusters: async () => [],
    getK8sScheduledBackups: async () => [],
    getK8sVeleroBackups: async () => [],
    getK8sLonghornJobs: async () => [],
    getArgocdApps: async () => [],
    getArgocdWarnings: async () => [],
    getManagerProxmox: async () => [],
    getManagerHealth: async () => ({ status: "ok" }),
    createChatCompletion: async (_provider, apiKey) => {
      observedApiKey = apiKey;
      return {
        choices: [{ message: { content: "De lokale AI endpoint werkt zonder API key." } }],
        model: "local-model",
      };
    },
    getProviderConfig: () => ({ baseUrl: "http://local-ai.example/v1", model: "local-model" }),
    getApiKey: () => null,
  });

  const result = await executor.executeWorkOrder(wo);
  assert.equal(observedApiKey, null);
  assert.equal(result.result.llmStatus, "ok");
  assert.equal(result.result.llmModel, "local-model");
});

test("executor handles LLM failure gracefully", async () => {
  const dataDir = tempDir();
  const eventStore = createEventStore(dataDir);
  const workOrderStore = createWorkOrderStore(dataDir);
  const wo = makeWorkOrder(dataDir, { type: "cluster_health_check" });

  const executor = createWorkflowExecutor({
    eventStore,
    workOrderStore,
    getK8sUnhealthyPods: async () => [],
    getK8sWarningEvents: async () => [],
    getK8sNodes: async () => [{ name: "node-1", ready: true }],
    getK8sCnpgClusters: async () => [],
    getK8sScheduledBackups: async () => [],
    getK8sVeleroBackups: async () => [],
    getK8sLonghornJobs: async () => [],
    getArgocdApps: async () => [],
    getArgocdWarnings: async () => [],
    getManagerProxmox: async () => [],
    getManagerHealth: async () => ({ status: "ok" }),
    createChatCompletion: async () => {
      throw new Error("LLM endpoint timeout");
    },
    getProviderConfig: () => ({ baseUrl: "http://test/v1", model: "test" }),
    getApiKey: () => "test-key",
  });

  const result = await executor.executeWorkOrder(wo);
  assert.ok(result);
  assert.equal(result.result.llmStatus, "error");
  assert.ok(result.result.llmError);
  assert.equal(result.result.llmSummary, null);
  assert.ok(result.evidence);
});

test("executor handles unknown work order type", async () => {
  const dataDir = tempDir();
  const eventStore = createEventStore(dataDir);
  const workOrderStore = createWorkOrderStore(dataDir);
  const wo = makeWorkOrder(dataDir, { type: "something_unknown" });

  const executor = createWorkflowExecutor({
    eventStore,
    workOrderStore,
    getK8sUnhealthyPods: async () => [],
    getK8sWarningEvents: async () => [],
    getK8sNodes: async () => [],
    getK8sCnpgClusters: async () => [],
    getK8sScheduledBackups: async () => [],
    getK8sVeleroBackups: async () => [],
    getK8sLonghornJobs: async () => [],
    getArgocdApps: async () => [],
    getArgocdWarnings: async () => [],
    getManagerProxmox: async () => [],
    getManagerHealth: async () => ({ status: "ok" }),
    createChatCompletion: async () => {
      throw new Error("should not be called");
    },
    getProviderConfig: () => null,
    getApiKey: () => null,
  });

  const result = await executor.executeWorkOrder(wo);
  assert.ok(result);
  assert.equal(result.status, "failed");
});

test("executor calls Zulip when postCoordinatorMessage is provided", async () => {
  const dataDir = tempDir();
  const eventStore = createEventStore(dataDir);
  const workOrderStore = createWorkOrderStore(dataDir);
  const wo = makeWorkOrder(dataDir, {
    type: "cluster_health_check",
    assignedAgents: ["olivia-ops", "karel-kubernetes"],
  });

  let zulipCalled = false;
  let zulipContent = "";

  const executor = createWorkflowExecutor({
    eventStore,
    workOrderStore,
    getK8sUnhealthyPods: async () => [],
    getK8sWarningEvents: async () => [],
    getK8sNodes: async () => [{ name: "node-1", ready: true }],
    getK8sCnpgClusters: async () => [],
    getK8sScheduledBackups: async () => [],
    getK8sVeleroBackups: async () => [],
    getK8sLonghornJobs: async () => [],
    getArgocdApps: async () => [],
    getArgocdWarnings: async () => [],
    getManagerProxmox: async () => [],
    getManagerHealth: async () => ({ status: "ok" }),
    createChatCompletion: async () => ({
      choices: [{ message: { content: "Alles gezond." } }],
      model: "test",
    }),
    getProviderConfig: () => ({ baseUrl: "http://test/v1", model: "test" }),
    getApiKey: () => "test-key",
    postCoordinatorMessage: async ({ topic, content }) => {
      zulipCalled = true;
      assert.equal(topic, "AI beheerteam");
      zulipContent = content;
    },
  });

  const result = await executor.executeWorkOrder(wo);
  assert.ok(result);
  assert.ok(zulipCalled);
  assert.ok(zulipContent.includes("Olivia Ops"));
  assert.ok(zulipContent.includes(wo.id));
  assert.ok(zulipContent.includes("karel-kubernetes") || zulipContent.includes("Karel"));
});

test("executor does not call Zulip when postCoordinatorMessage is not provided", async () => {
  const dataDir = tempDir();
  const eventStore = createEventStore(dataDir);
  const workOrderStore = createWorkOrderStore(dataDir);
  const wo = makeWorkOrder(dataDir, { type: "backup_health_check" });

  const executor = createWorkflowExecutor({
    eventStore,
    workOrderStore,
    getK8sUnhealthyPods: async () => [],
    getK8sWarningEvents: async () => [],
    getK8sNodes: async () => [],
    getK8sCnpgClusters: async () => [],
    getK8sScheduledBackups: async () => [],
    getK8sVeleroBackups: async () => [],
    getK8sLonghornJobs: async () => [],
    getArgocdApps: async () => [],
    getArgocdWarnings: async () => [],
    getManagerProxmox: async () => [],
    getManagerHealth: async () => ({ status: "ok" }),
    createChatCompletion: async () => ({
      choices: [{ message: { content: "Alles ok." } }],
      model: "test",
    }),
    getProviderConfig: () => ({ baseUrl: "http://test/v1", model: "test" }),
    getApiKey: () => "test-key",
  });

  const result = await executor.executeWorkOrder(wo);
  assert.ok(result);
  assert.equal(result.status, "proposal_ready");
});
