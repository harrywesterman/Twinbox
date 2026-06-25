import test from "node:test";
import assert from "node:assert/strict";
import os from "node:os";
import path from "node:path";
import fs from "node:fs";
import { createWorkOrderStore } from "../src/work-orders.mjs";

function tempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "wo-test-"));
}

test("work-orders create and get", () => {
  const dataDir = tempDir();
  const store = createWorkOrderStore(dataDir);

  const wo = store.createWorkOrder({
    type: "cluster_health_check",
    title: "Test check",
    createdBy: "admin",
  });

  assert.ok(wo.id);
  assert.equal(wo.status, "new");
  assert.equal(wo.type, "cluster_health_check");

  const fetched = store.getWorkOrder(wo.id);
  assert.ok(fetched);
  assert.equal(fetched.id, wo.id);
});

test("work-orders list supports status filter", () => {
  const dataDir = tempDir();
  const store = createWorkOrderStore(dataDir);

  store.createWorkOrder({ type: "backup_health_check", title: "WO 1", createdBy: "admin" });
  const wo2 = store.createWorkOrder({
    type: "cluster_health_check",
    title: "WO 2",
    createdBy: "admin",
  });

  store.updateWorkOrder(wo2.id, { status: "completed" });

  const pending = store.listWorkOrders({ status: "new" });
  assert.equal(pending.length, 1);
  assert.equal(pending[0].title, "WO 1");

  const completed = store.listWorkOrders({ status: "completed" });
  assert.equal(completed.length, 1);
  assert.equal(completed[0].title, "WO 2");
});

test("work-orders lifecycle", () => {
  const dataDir = tempDir();
  const store = createWorkOrderStore(dataDir);

  const wo = store.createWorkOrder({
    type: "cluster_health_check",
    title: "Lifecycle",
    createdBy: "admin",
  });
  assert.equal(wo.status, "new");

  store.updateWorkOrder(wo.id, { status: "assigned" });
  assert.equal(store.getWorkOrder(wo.id).status, "assigned");

  store.updateWorkOrder(wo.id, { status: "investigating" });
  assert.equal(store.getWorkOrder(wo.id).status, "investigating");
});

test("work-orders approval request", () => {
  const dataDir = tempDir();
  const store = createWorkOrderStore(dataDir);

  const wo = store.createWorkOrder({
    type: "cluster_health_check",
    title: "Approval test",
    createdBy: "admin",
  });

  const updated = store.createApprovalRequest(wo.id, {
    actionKind: "manager_job",
    action: "restart_deployment",
    parameters: { namespace: "default", deployment: "test" },
    risk: "Restarts pods",
    rollback: "Use previous ReplicaSet",
    requestedByAgent: "olivia-ops",
  });

  assert.ok(updated.approval);
  assert.ok(updated.approval.id);
  assert.equal(updated.approval.status, "pending");

  store.approveWorkOrder(wo.id, "admin");
  assert.equal(store.getWorkOrder(wo.id).status, "approved");

  const wo2 = store.createWorkOrder({
    type: "backup_health_check",
    title: "Cancel test",
    createdBy: "admin",
  });
  store.cancelWorkOrder(wo2.id, "admin");
  assert.equal(store.getWorkOrder(wo2.id).status, "canceled");
});

test("work-orders list returns newest first", async () => {
  const dataDir = tempDir();
  const store = createWorkOrderStore(dataDir);

  store.createWorkOrder({
    type: "cluster_health_check",
    title: "First",
    createdBy: "admin",
  });
  await new Promise((r) => setTimeout(r, 5));
  store.createWorkOrder({
    type: "backup_health_check",
    title: "Second",
    createdBy: "admin",
  });

  const all = store.listWorkOrders({});
  assert.equal(all[0].title, "Second");
  assert.equal(all[1].title, "First");
});
