import { redactObject } from "./redaction.mjs";

function createWorkflowExecutor(deps) {
  const {
    eventStore,
    workOrderStore,
    getK8sUnhealthyPods,
    getK8sWarningEvents,
    getK8sNodes,
    getK8sCnpgClusters,
    getK8sScheduledBackups,
    getK8sVeleroBackups,
    getK8sLonghornJobs,
    getArgocdApps,
    getArgocdWarnings,
    getManagerProxmox,
    getManagerHealth,
    createChatCompletion,
    getProviderConfig,
    getApiKey,
    postCoordinatorMessage,
  } = deps;

  const FACT_GATHERERS = {
    cluster_health_check: gatherClusterFacts,
    backup_health_check: gatherBackupFacts,
    proxmox_health_check: gatherProxmoxFacts,
    database_health_check: gatherDatabaseFacts,
    gitops_health_check: gatherGitopsFacts,
  };

  function appendEvent(workOrderId, fields) {
    eventStore.appendEvent({
      agentId: fields.agentId || "system",
      workOrderId,
      type: fields.type || "status",
      severity: fields.severity || "info",
      title: fields.title || "",
      message: fields.message || "",
      metadata: fields.metadata || {},
    });
  }

  async function gatherClusterFacts() {
    const facts = {};
    const unhealthyPods = await safeCall(getK8sUnhealthyPods);
    facts.unhealthyPods = redactObject(unhealthyPods);
    const warningEvents = await safeCall(getK8sWarningEvents);
    facts.warningEvents = redactObject(warningEvents);
    const nodes = await safeCall(getK8sNodes);
    facts.nodes = redactObject(nodes);
    return facts;
  }

  async function gatherBackupFacts() {
    const facts = {};
    const velero = await safeCall(getK8sVeleroBackups);
    facts.veleroBackups = redactObject(velero);
    const longhorn = await safeCall(getK8sLonghornJobs);
    facts.longhornRecurringJobs = redactObject(longhorn);
    const cnpg = await safeCall(getK8sScheduledBackups);
    facts.cnpgScheduledBackups = redactObject(cnpg);
    return facts;
  }

  async function gatherProxmoxFacts() {
    const facts = {};
    const proxmox = await safeCall(getManagerProxmox);
    facts.proxmoxResources = redactObject(proxmox);
    const mgmtHealth = await safeCall(getManagerHealth);
    facts.managerApiHealth = redactObject(mgmtHealth);
    if (proxmox && (proxmox.error || proxmox.available === false)) {
      facts.proxmoxUnavailable = true;
    }
    return facts;
  }

  async function gatherDatabaseFacts() {
    const facts = {};
    const clusters = await safeCall(getK8sCnpgClusters);
    facts.cnpgClusters = redactObject(clusters);
    const backups = await safeCall(getK8sScheduledBackups);
    facts.cnpgScheduledBackups = redactObject(backups);
    return facts;
  }

  async function gatherGitopsFacts() {
    const facts = {};
    const apps = await safeCall(getArgocdApps);
    facts.argocdApplications = redactObject(apps);
    const warnings = await safeCall(getArgocdWarnings);
    facts.argocdWarnings = redactObject(warnings);
    return facts;
  }

  function buildFactsSummary(type, facts) {
    const lines = [`Facts gathered for ${type}:`];
    for (const [key, value] of Object.entries(facts)) {
      if (Array.isArray(value)) {
        lines.push(`- ${key}: ${value.length} item(s)`);
        for (const item of value.slice(0, 5)) {
          const label = item.name || item.id || JSON.stringify(item).slice(0, 80);
          lines.push(`  - ${label}`);
        }
        if (value.length > 5) {
          lines.push(`  (... and ${value.length - 5} more)`);
        }
      } else if (value && typeof value === "object") {
        const summary = value.error
          ? `unavailable: ${value.error}`
          : `${Object.keys(value).length} keys`;
        lines.push(`- ${key}: ${summary}`);
      } else {
        lines.push(`- ${key}: ${value}`);
      }
    }
    return lines.join("\n");
  }

  function buildSystemPrompt(type) {
    const prompts = {
      cluster_health_check:
        "You are a Kubernetes operations specialist. Summarize the cluster health in Dutch based on the provided facts. " +
        "Include evidence. Do not recommend deleting resources. If action is needed, describe it as a proposal. " +
        "Classify the overall status as healthy/degraded/critical.",
      backup_health_check:
        "You are a backup operations specialist. Summarize the backup health in Dutch based on the provided facts. " +
        "Classify as healthy/degraded/critical. List any missing signals. " +
        "Do not claim restore works unless there is evidence of a successful restore test.",
      proxmox_health_check:
        "You are a Proxmox infrastructure specialist. Summarize the Proxmox cluster health in Dutch based on the provided facts. " +
        "Include evidence. If manager-api is unreachable, note this and classify as degraded.",
      database_health_check:
        "You are a database operations specialist. Summarize the CloudNativePG database health in Dutch based on the provided facts. " +
        "Include CNPG cluster conditions, pod readiness, and backup status. Do not attempt to connect to databases directly.",
      gitops_health_check:
        "You are a GitOps specialist. Summarize the Argo CD application sync status in Dutch based on the provided facts. " +
        "Include sync and health status per application. Note any warning events in the argocd namespace.",
    };
    return (
      prompts[type] || "Summarize the operational status in Dutch based on the provided facts."
    );
  }

  async function generateSummary(type, facts) {
    const rawText = buildFactsSummary(type, facts);
    const provider = getProviderConfig();
    const apiKey = getApiKey();

    if (!provider) {
      return {
        summary: null,
        rawFacts: rawText,
        llmStatus: "unconfigured",
      };
    }

    try {
      const response = await createChatCompletion(
        provider,
        apiKey,
        [
          { role: "system", content: buildSystemPrompt(type) },
          {
            role: "user",
            content: `Here are the operational facts:\n\n${rawText}\n\nProvide a concise Dutch summary.`,
          },
        ],
        { timeoutMs: 60000, extraBody: { temperature: 0.3, max_tokens: 1000 } }
      );
      const content = response.choices?.[0]?.message?.content || "";
      return {
        summary: content,
        rawFacts: rawText,
        llmStatus: "ok",
        model: response.model || provider.model,
      };
    } catch (err) {
      return {
        summary: null,
        rawFacts: rawText,
        llmStatus: "error",
        llmError: err.message,
      };
    }
  }

  function buildZulipMessage(workOrder, summaryResult) {
    const statusLabels = {
      proposal_ready: "Onderzoek voltooid",
      degraded: "Gedegradeerd",
      failed: "Mislukt",
    };
    const label = statusLabels[workOrder.status] || workOrder.status;
    const experts =
      workOrder.assignedAgents?.length > 0
        ? workOrder.assignedAgents
            .map((a) => a.charAt(0).toUpperCase() + a.slice(1).replace(/-/g, " "))
            .join(", ")
        : "Geen";
    let summary = summaryResult?.summary || "Geen samenvatting beschikbaar.";
    summary = summary.slice(0, 1500);
    const content = `**Olivia Ops** - ${label}\n\n${summary}\n\nBetrokken experts: ${experts}\nWork order: ${workOrder.id}\nStatus: ${workOrder.status}`;
    return content;
  }

  async function tryPostZulip(workOrder, summaryResult) {
    if (typeof postCoordinatorMessage !== "function") return;
    try {
      const content = buildZulipMessage(workOrder, summaryResult);
      const result = await postCoordinatorMessage({
        topic: "AI beheerteam",
        content,
      });
      if (result?.skipped) {
        appendEvent(workOrder.id, {
          agentId: "olivia-ops",
          title: "Zulip overgeslagen",
          message: "Zulip integration is not configured.",
        });
        return;
      }
      appendEvent(workOrder.id, {
        agentId: "olivia-ops",
        title: "Zulip bericht geplaatst",
        message: "Olivia Ops posted the work order summary to Zulip.",
        metadata: { topic: "AI beheerteam" },
      });
    } catch {
      appendEvent(workOrder.id, {
        agentId: "olivia-ops",
        severity: "warning",
        title: "Zulip bericht mislukt",
        message: "Olivia Ops could not post the work order summary to Zulip.",
      });
    }
  }

  async function executeWorkOrder(workOrder) {
    const { id, type } = workOrder;
    const gatherer = FACT_GATHERERS[type];

    if (!gatherer) {
      workOrderStore.updateWorkOrder(id, {
        status: "failed",
        result: { error: `unknown work order type: ${type}` },
      });
      appendEvent(id, {
        agentId: "system",
        severity: "error",
        title: "Execution failed",
        message: `Unknown work order type: ${type}`,
      });
      return workOrderStore.getWorkOrder(id);
    }

    appendEvent(id, {
      agentId: "system",
      title:
        type === "cluster_health_check"
          ? "Clustercontrole gestart"
          : `${type} investigation started`,
      message: `Gathering facts for ${type}`,
    });

    const facts = await gatherer();

    const hasUnavailableData = Object.values(facts).some(
      (v) => v && typeof v === "object" && (v.available === false || v.error)
    );

    appendEvent(id, {
      agentId: "system",
      title: "Facts gathered",
      message: `Collected ${Object.keys(facts).length} fact categories.`,
    });

    const summaryResult = await generateSummary(type, facts);

    if (summaryResult.llmStatus === "ok") {
      appendEvent(id, {
        agentId: "system",
        title: hasUnavailableData ? "Voorstel klaar (gedeeltelijk)" : "Voorstel klaar",
        message: "LLM summary generated successfully.",
      });
    } else if (summaryResult.llmStatus === "unconfigured") {
      appendEvent(id, {
        agentId: "system",
        severity: "warning",
        title: "AI endpoint unavailable",
        message: "No LLM endpoint configured. Saving raw facts only.",
      });
    } else {
      appendEvent(id, {
        agentId: "system",
        severity: "warning",
        title: "AI endpoint error",
        message: `LLM summary failed: ${summaryResult.llmError}. Saving raw facts.`,
      });
    }

    const finalStatus = hasUnavailableData ? "degraded" : "proposal_ready";

    workOrderStore.updateWorkOrder(id, {
      status: finalStatus,
      evidence: [summaryResult.rawFacts],
      result: {
        facts,
        llmSummary: summaryResult.summary,
        llmStatus: summaryResult.llmStatus,
        llmModel: summaryResult.model || null,
        llmError: summaryResult.llmError || null,
      },
    });

    const updated = workOrderStore.getWorkOrder(id);

    const specialistId = findSpecialistForType(type);
    const completionTitle =
      finalStatus === "degraded"
        ? "Onderzoek afgerond met aandachtspunten"
        : "Geen kritieke problemen gevonden";
    appendEvent(id, {
      agentId: specialistId || "system",
      title: completionTitle,
      message: `Work order ${id} completed with status ${finalStatus}.`,
    });

    if (finalStatus !== "failed") {
      await tryPostZulip(updated, summaryResult);
    }

    return updated;
  }

  return { executeWorkOrder };
}

function findSpecialistForType(type) {
  const map = {
    cluster_health_check: "karel-kubernetes",
    backup_health_check: "betty-backup",
    proxmox_health_check: "peter-proxmox",
    database_health_check: "sofia-sql",
    gitops_health_check: "gina-gitops",
  };
  return map[type] || null;
}

async function safeCall(fn) {
  try {
    return await fn();
  } catch (err) {
    return { error: err.message, available: false };
  }
}

export { createWorkflowExecutor };
