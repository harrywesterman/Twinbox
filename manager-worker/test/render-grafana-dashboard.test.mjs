import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "child_process";
import path from "path";
import { fileURLToPath } from "url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

function renderDashboard(name) {
  const output = execFileSync("node", ["scripts/manager/render-grafana-dashboard.mjs", name], {
    cwd: repoRoot,
    encoding: "utf8",
  });
  return JSON.parse(output);
}

function panelByTitle(dashboard, title) {
  return dashboard.panels.find((panel) => panel.title === title);
}

test("network dashboard uses a rate window long enough for the full Prometheus scrape interval", () => {
  const dashboard = renderDashboard("network");

  assert.match(panelByTitle(dashboard, "Total RX").targets[0].expr, /\[15m\]/);
  assert.match(panelByTitle(dashboard, "Total TX").targets[0].expr, /\[15m\]/);
  assert.match(panelByTitle(dashboard, "Packet errors").targets[0].expr, /\[15m\]/);
  assert.match(panelByTitle(dashboard, "Node RX/TX").targets[0].expr, /\[15m\]/);
  assert.match(panelByTitle(dashboard, "Node RX/TX").targets[1].expr, /\[15m\]/);
  assert.match(panelByTitle(dashboard, "Top pod RX").targets[0].expr, /\[15m\]/);
  assert.match(panelByTitle(dashboard, "Top pod TX").targets[0].expr, /\[15m\]/);
  assert.match(
    panelByTitle(dashboard, "Network policies").targets[0].expr,
    /count\(kube_networkpolicy_created\)/
  );
  assert.equal(
    panelByTitle(dashboard, "Network policy coverage by namespace").targets[0].expr,
    "count by (namespace) (kube_networkpolicy_created)"
  );
});

test("nodes dashboard uses the same longer network rate window", () => {
  const dashboard = renderDashboard("nodes");
  const panel = panelByTitle(dashboard, "Network throughput by node");

  assert.match(panel.targets[0].expr, /\[15m\]/);
  assert.match(panel.targets[1].expr, /\[15m\]/);
});
