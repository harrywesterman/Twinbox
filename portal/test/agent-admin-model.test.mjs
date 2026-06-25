import test from "node:test";
import assert from "node:assert/strict";
import {
  buildAgentAdminViewModel,
  buildProviderHealthLabel,
  groupEventsByWorkOrder,
} from "../src/agent-admin-model.js";

test("buildAgentAdminViewModel with empty data", () => {
  const vm = buildAgentAdminViewModel({});
  assert.ok(vm);
  assert.equal(vm.agents.length, 0);
  assert.deepEqual(vm.events, []);
  assert.deepEqual(vm.workOrders, []);
  assert.equal(vm.hasProvider, false);
  assert.equal(vm.isDegraded, true);
});

test("buildAgentAdminViewModel handles degraded mode", () => {
  const vm = buildAgentAdminViewModel({
    agents: { degraded: true },
    agentTokenConfigured: false,
  });
  assert.equal(vm.isDegraded, true);
});

test("buildAgentAdminViewModel with agents and provider", () => {
  const vm = buildAgentAdminViewModel({
    agents: [
      {
        id: "olivia-ops",
        displayName: "Olivia Ops",
        role: "Coordinator",
        public: true,
        avatar: { initials: "OO", palette: "purple" },
        summary: "Coordinates",
      },
      {
        id: "betty-backup",
        displayName: "Betty Backup",
        role: "Backup",
        public: false,
        avatar: { initials: "BB", palette: "green" },
        summary: "Backups",
      },
    ],
    providers: { config: { baseUrl: "http://localhost:8080/v1" }, hasApiKey: true },
    events: [{ id: "evt_1", title: "Started" }],
    workOrders: [
      {
        id: "wo_1",
        status: "approval_required",
        approval: { status: "pending" },
      },
    ],
    agentTokenConfigured: true,
  });
  assert.equal(vm.agents.length, 2);
  assert.equal(vm.hasProvider, true);
  assert.equal(vm.hasApiKey, true);
  assert.equal(vm.isDegraded, false);
  assert.equal(vm.teamSummary.totalAgents, 2);
  assert.equal(vm.teamSummary.activeWorkOrders, 1);
  assert.equal(vm.workOrders[0].hasPendingApproval, true);
  assert.equal(vm.events.length, 1);
});

test("buildProviderHealthLabel handles null", () => {
  assert.equal(buildProviderHealthLabel(null), "Niet geconfigureerd");
});

test("buildProviderHealthLabel handles provider", () => {
  assert.equal(buildProviderHealthLabel({ displayName: "Test AI" }), "Test AI");
  assert.equal(buildProviderHealthLabel({ baseUrl: "http://test/v1" }), "http://test/v1");
  assert.equal(
    buildProviderHealthLabel({ config: { displayName: "Nested AI", baseUrl: "http://test/v1" } }),
    "Nested AI"
  );
});

test("groupEventsByWorkOrder handles empty", () => {
  const grouped = groupEventsByWorkOrder([]);
  assert.deepEqual(grouped, {});
});

test("groupEventsByWorkOrder groups events", () => {
  const events = [
    { id: "1", workOrderId: "wo_001", title: "Event 1" },
    { id: "2", workOrderId: "wo_001", title: "Event 2" },
    { id: "3", workOrderId: "wo_002", title: "Event 3" },
    { id: "4", workOrderId: null, title: "General" },
  ];
  const grouped = groupEventsByWorkOrder(events);
  assert.ok(grouped["wo_001"]);
  assert.equal(grouped["wo_001"].length, 2);
  assert.ok(grouped["wo_002"]);
  assert.equal(grouped["wo_002"].length, 1);
  assert.ok(grouped["__general"]);
  assert.equal(grouped["__general"].length, 1);
});
