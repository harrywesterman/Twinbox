import test from "node:test";
import assert from "node:assert/strict";

import { IT_DEPARTMENT_AGENTS, buildItDepartmentScene } from "../src/it-department-model.js";

test("IT department agents have stable unique identities", () => {
  const ids = IT_DEPARTMENT_AGENTS.map((agent) => agent.id);
  const names = IT_DEPARTMENT_AGENTS.map((agent) => agent.displayName);

  assert.equal(IT_DEPARTMENT_AGENTS.length, 7);
  assert.equal(new Set(ids).size, IT_DEPARTMENT_AGENTS.length);
  assert.equal(new Set(names).size, IT_DEPARTMENT_AGENTS.length);
  assert.deepEqual(names, [
    "Olivia Ops",
    "Karel Kubernetes",
    "Betty Backup",
    "Peter Proxmox",
    "Tara Talos",
    "Sofia SQL",
    "Gina GitOps",
  ]);
});

test("IT department scene positions stay within the pixel office floor", () => {
  for (const agent of IT_DEPARTMENT_AGENTS) {
    assert.ok(agent.x >= 0 && agent.x <= 100, `${agent.id} x position is out of range`);
    assert.ok(agent.y >= 0 && agent.y <= 100, `${agent.id} y position is out of range`);
    assert.match(agent.initials, /^[A-Z]{2}$/);
    assert.ok(agent.role.length > 0);
    assert.ok(agent.station.length > 0);
  }
});

test("buildItDepartmentScene returns public visual-only metadata", () => {
  const scene = buildItDepartmentScene();

  assert.equal(scene.title, "IT department");
  assert.equal(scene.eyebrow, "Pixel office");
  assert.equal(scene.agents.length, IT_DEPARTMENT_AGENTS.length);
  assert.equal(scene.stats.find((stat) => stat.id === "staff")?.value, IT_DEPARTMENT_AGENTS.length);
  assert.equal(scene.stats.find((stat) => stat.id === "active")?.value, 0);
  assert.ok(scene.agents.every((agent) => Number.isInteger(agent.zIndex)));
});

test("buildItDepartmentScene maps live AI agent work to pixel motion", () => {
  const scene = buildItDepartmentScene({
    fetchedAt: "2026-06-26T10:00:00.000Z",
    agents: [
      {
        id: "karel-kubernetes",
        displayName: "Karel Kubernetes",
        role: "Kubernetes Specialist",
        avatar: { initials: "KK" },
        systemPrompt: "do not leak me",
      },
    ],
    workOrders: [
      {
        id: "wo_1",
        type: "cluster_health_check",
        title: "Sensitive title should not appear",
        status: "investigating",
        assignedAgents: ["olivia-ops", "karel-kubernetes"],
        updatedAt: "2026-06-26T09:59:00.000Z",
        result: { secret: "nope" },
        evidence: ["nope"],
      },
    ],
    events: [
      {
        id: "event-1",
        agentId: "karel-kubernetes",
        workOrderId: "wo_1",
        severity: "info",
        title: "Raw event title",
        message: "Raw event message",
        metadata: { secret: "nope" },
        timestamp: "2026-06-26T09:59:30.000Z",
      },
    ],
  });

  const karel = scene.agents.find((agent) => agent.id === "karel-kubernetes");
  const olivia = scene.agents.find((agent) => agent.id === "olivia-ops");
  const serialized = JSON.stringify(scene);

  assert.equal(karel.motion, "walking");
  assert.equal(karel.status, "investigating");
  assert.equal(karel.activity, "cluster watch: investigating");
  assert.equal(karel.role, "Kubernetes Specialist");
  assert.equal(olivia.motion, "walking");
  assert.equal(scene.stats.find((stat) => stat.id === "active")?.value, 2);
  assert.equal(serialized.includes("Sensitive title"), false);
  assert.equal(serialized.includes("Raw event message"), false);
  assert.equal(serialized.includes("systemPrompt"), false);
  assert.equal(serialized.includes("secret"), false);
});

test("buildItDepartmentScene falls back to degraded pixel office state", () => {
  const scene = buildItDepartmentScene({
    degraded: true,
    fetchedAt: "2026-06-26T10:00:00.000Z",
  });

  assert.equal(scene.degraded, true);
  assert.equal(scene.liveLabel, "offline");
  assert.ok(scene.agents.every((agent) => agent.motion === "alert"));
  assert.ok(scene.agents.every((agent) => agent.activity === "agent link offline"));
});
