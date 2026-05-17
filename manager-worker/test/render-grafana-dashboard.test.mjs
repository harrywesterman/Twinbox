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

function panelDatasources(dashboard) {
  return dashboard.panels.map((panel) => panel.datasource).filter(Boolean);
}

test("new Twinbox overview dashboards render expected metadata and datasources", () => {
  const expectations = [
    {
      name: "commandCenter",
      uid: "twinbox-command-center",
      title: "Twinbox Command Center",
      tags: ["overview", "command-center", "status"],
    },
    {
      name: "appsGitOps",
      uid: "twinbox-apps-gitops",
      title: "Twinbox Apps & GitOps",
      tags: ["apps", "gitops", "argocd"],
    },
    {
      name: "dataProtection",
      uid: "twinbox-data-protection",
      title: "Twinbox Data Protection",
      tags: ["backup", "storage", "longhorn", "velero", "cloudnativepg"],
    },
  ];

  for (const expectation of expectations) {
    const dashboard = renderDashboard(expectation.name);

    assert.equal(dashboard.uid, expectation.uid);
    assert.equal(dashboard.title, expectation.title);
    assert.equal(dashboard.tags[0], "twinbox");
    for (const tag of expectation.tags) {
      assert.equal(dashboard.tags.includes(tag), true);
    }
    assert.equal(dashboard.panels.length > 0, true);
    assert.deepEqual(new Set(panelDatasources(dashboard)), new Set(["Prometheus", "Loki"]));
  }
});

test("new overview dashboards use the shared scrape-safe rate window for pressure panels", () => {
  const commandCenter = renderDashboard("commandCenter");
  const appsGitOps = renderDashboard("appsGitOps");

  assert.match(panelByTitle(commandCenter, "Cluster CPU").targets[0].expr, /\[15m\]/);
  assert.match(panelByTitle(commandCenter, "Network errors / s").targets[0].expr, /\[15m\]/);
  assert.match(panelByTitle(commandCenter, "Cluster resource pressure").targets[0].expr, /\[15m\]/);
  assert.match(panelByTitle(appsGitOps, "Top app CPU").targets[0].expr, /\[15m\]/);
});

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
