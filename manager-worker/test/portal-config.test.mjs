import test from "node:test";
import assert from "node:assert/strict";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

import YAML from "yaml";

import { normalizeStepManifest } from "../../lib/step-manifest.mjs";
import { buildPortalConfig } from "../../lib/portal-config.mjs";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

function loadStep(stepId) {
  const file = path.join(repoRoot, "categories", "talos-cluster", "steps", stepId, "step.yaml");
  const manifest = YAML.parse(fs.readFileSync(file, "utf8"));
  return normalizeStepManifest(manifest, file, "talos-cluster");
}

test("buildPortalConfig renders user and admin portals from the runtime catalog", () => {
  const steps = [
    loadStep("install-grafana"),
    loadStep("install-headlamp"),
    loadStep("install-management-consoles"),
    loadStep("install-dashy-dashboard"),
    loadStep("install-velero-ui"),
  ];

  const stepStateById = new Map([
    ["install-grafana", { status: "succeeded" }],
    ["install-headlamp", { status: "succeeded" }],
    ["install-management-consoles", { status: "succeeded" }],
    ["install-dashy-dashboard", { status: "succeeded" }],
    ["install-velero-ui", { status: "configured" }],
  ]);

  const config = buildPortalConfig({
    steps,
    stepStateById,
    cluster: {
      id: "tst",
      slug: "tst",
      dns_domain: "example.com",
    },
    content: JSON.parse(fs.readFileSync(path.join(repoRoot, "config", "portal", "content.json"), "utf8")),
  });

  assert.equal(config.portal.brand, "Twinbox");
  assert.equal(config.settings.issueUrl, "https://github.com/harrywesterman/Twinbox/issues/new/choose");
  assert.equal(config.userAdmin.title, "Gebruikers en groepen");
  assert.deepEqual(config.userAdmin.manageableGroups, []);
  assert(config.apps.some((card) => card.title === "Grafana"));
  assert(config.apps.some((card) => card.title === "Headlamp"));
  assert(config.apps.some((card) => card.title === "Velero UI"));
  assert(config.adminApps.some((card) => card.title === "Dashy"));
  assert(config.intranetLinks.some((card) => card.title === "Wizard"));
  assert(config.statusChecks.some((card) => card.title === "Authentik"));
  assert(config.apps.every((card) => card.liveUrl.startsWith("https://")));
});

test("buildPortalConfig skips apps that are not completed yet", () => {
  const steps = [loadStep("install-grafana")];
  const stepStateById = new Map([
    ["install-grafana", { status: "failed" }],
  ]);

  const config = buildPortalConfig({
    steps,
    stepStateById,
    cluster: {
      id: "tst",
      slug: "tst",
      dns_domain: "example.com",
    },
    content: JSON.parse(fs.readFileSync(path.join(repoRoot, "config", "portal", "content.json"), "utf8")),
  });

  assert.equal(config.apps.length, 0);
  assert(config.adminApps.length > 0);
});
