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
  assert.equal(scene.stats.find((stat) => stat.id === "mode")?.value, "visual");
  assert.equal(scene.stats.find((stat) => stat.id === "access")?.value, "all users");
  assert.ok(scene.agents.every((agent) => Number.isInteger(agent.zIndex)));
});
