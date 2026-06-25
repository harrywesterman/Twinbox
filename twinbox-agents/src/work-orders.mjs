import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  renameSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import { randomBytes } from "node:crypto";
import { randomUUID } from "node:crypto";

const VALID_STATUSES = [
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
];

const VALID_TYPES = [
  "cluster_health_check",
  "backup_health_check",
  "proxmox_health_check",
  "database_health_check",
  "gitops_health_check",
];

function createWorkOrderStore(dataDir) {
  const effectiveDataDir = process.env.AGENT_DATA_DIR || dataDir || "/data";
  const workOrdersDir = join(effectiveDataDir, "work-orders");

  function ensureDir() {
    if (!existsSync(workOrdersDir)) {
      mkdirSync(workOrdersDir, { recursive: true });
    }
  }

  function generateId() {
    const ts = Date.now().toString(36);
    const rand = randomBytes(4).toString("hex");
    return `wo_${ts}_${rand}`;
  }

  function workOrderPath(id) {
    return join(workOrdersDir, `${id}.json`);
  }

  function readWorkOrder(id) {
    const filePath = workOrderPath(id);
    if (!existsSync(filePath)) {
      return null;
    }
    return JSON.parse(readFileSync(filePath, "utf-8"));
  }

  function writeWorkOrder(workOrder) {
    ensureDir();
    const filePath = workOrderPath(workOrder.id);
    const tmpFile = filePath + ".tmp";
    writeFileSync(tmpFile, JSON.stringify(workOrder, null, 2), "utf-8");
    renameSync(tmpFile, filePath);
  }

  function createWorkOrder(fields) {
    const now = new Date().toISOString();
    const workOrder = {
      id: generateId(),
      createdAt: now,
      updatedAt: now,
      createdBy: fields.createdBy || "system",
      source: fields.source || "api",
      type: fields.type || "cluster_health_check",
      status: "new",
      title: fields.title || "",
      scope: fields.scope || null,
      assignedAgents: fields.assignedAgents || [],
      evidence: [],
      proposal: null,
      approval: null,
      result: null,
    };
    writeWorkOrder(workOrder);
    return workOrder;
  }

  function getWorkOrder(id) {
    return readWorkOrder(id);
  }

  function listWorkOrders({ status, limit } = {}) {
    ensureDir();
    const files = existsSync(workOrdersDir)
      ? readdirSync(workOrdersDir).filter((f) => f.endsWith(".json"))
      : [];
    const workOrders = [];
    for (const file of files) {
      try {
        const wo = JSON.parse(readFileSync(join(workOrdersDir, file), "utf-8"));
        if (status && wo.status !== status) {
          continue;
        }
        workOrders.push(wo);
      } catch {
        // skip malformed files
      }
    }
    workOrders.sort((a, b) => {
      const da = new Date(a.createdAt || 0).getTime();
      const db = new Date(b.createdAt || 0).getTime();
      if (da !== db) return db - da;
      return String(b.id).localeCompare(String(a.id));
    });
    const effectiveLimit = limit || 100;
    return workOrders.slice(0, effectiveLimit);
  }

  function updateWorkOrder(id, patch) {
    const wo = readWorkOrder(id);
    if (!wo) {
      return null;
    }
    const updated = { ...wo, ...patch, updatedAt: new Date().toISOString() };
    writeWorkOrder(updated);
    return updated;
  }

  function createApprovalRequest(workOrderId, request) {
    const wo = readWorkOrder(workOrderId);
    if (!wo) {
      return null;
    }
    const approvalRequest = {
      id: request.id || randomUUID(),
      workOrderId,
      status: "pending",
      actionKind: request.actionKind || "unknown",
      action: request.action || "",
      parameters: request.parameters || {},
      risk: request.risk || "low",
      rollback: request.rollback || "",
      requestedByAgent: request.requestedByAgent || "system",
      approvedBy: null,
      approvedAt: null,
    };
    const updated = {
      ...wo,
      status: "approval_required",
      approval: approvalRequest,
      updatedAt: new Date().toISOString(),
    };
    writeWorkOrder(updated);
    return updated;
  }

  function approveWorkOrder(workOrderId, approver) {
    const wo = readWorkOrder(workOrderId);
    if (!wo) {
      return null;
    }
    if (!wo.approval) {
      return null;
    }
    const updated = {
      ...wo,
      status: "approved",
      approval: {
        ...wo.approval,
        status: "approved",
        approvedBy: approver,
        approvedAt: new Date().toISOString(),
      },
      updatedAt: new Date().toISOString(),
    };
    writeWorkOrder(updated);
    return updated;
  }

  function cancelWorkOrder(workOrderId, actor) {
    const wo = readWorkOrder(workOrderId);
    if (!wo) {
      return null;
    }
    const updated = {
      ...wo,
      status: "canceled",
      result: { canceledBy: actor, canceledAt: new Date().toISOString() },
      updatedAt: new Date().toISOString(),
    };
    writeWorkOrder(updated);
    return updated;
  }

  return {
    createWorkOrder,
    getWorkOrder,
    listWorkOrders,
    updateWorkOrder,
    createApprovalRequest,
    approveWorkOrder,
    cancelWorkOrder,
  };
}

export { createWorkOrderStore, VALID_STATUSES, VALID_TYPES };
