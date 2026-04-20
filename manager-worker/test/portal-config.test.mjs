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

function loadAppStep(stepId) {
  const file = path.join(repoRoot, "categories", "apps", "steps", stepId, "step.yaml");
  const manifest = YAML.parse(fs.readFileSync(file, "utf8"));
  return normalizeStepManifest(manifest, file, "apps");
}

test("buildPortalConfig keeps operator tools out of the user applications grid", () => {
  const steps = [
    loadStep("install-grafana"),
    loadStep("install-headlamp"),
    loadStep("install-management-consoles"),
    loadStep("install-dashy-dashboard"),
    loadStep("install-velero-ui"),
    loadAppStep("install-immich"),
  ];

  const stepStateById = new Map([
    ["install-grafana", { status: "succeeded" }],
    ["install-headlamp", { status: "succeeded" }],
    ["install-management-consoles", { status: "succeeded" }],
    ["install-dashy-dashboard", { status: "succeeded" }],
    ["install-velero-ui", { status: "configured" }],
    ["install-immich", { status: "failed" }],
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
  assert.equal(config.apps.length, 0);
  assert.equal(config.appSections.length, 1);
  assert.equal(config.appSections[0].name, "Apps");
  assert.equal(config.appSections[0].items.length, 0);
  assert(config.adminApps.some((card) => card.title === "Dashy"));
  assert(config.intranetLinks.some((card) => card.title === "Wizard"));
  assert(config.statusChecks.some((card) => card.title === "Authentik"));
  assert(config.apps.every((card) => card.liveUrl.startsWith("https://")));
});

test("buildPortalConfig shows user apps only after the app category is installed", () => {
  const steps = [
    loadStep("install-grafana"),
    loadAppStep("install-immich"),
  ];
  const stepStateById = new Map([
    ["install-grafana", { status: "succeeded" }],
    ["install-immich", { status: "succeeded" }],
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

  assert.deepEqual(config.apps.map((card) => card.title), ["Immich"]);
  assert.equal(config.appSections.length, 1);
  assert.equal(config.appSections[0].name, "Apps");
  assert.deepEqual(config.appSections[0].items.map((card) => card.title), ["Immich"]);
  assert.equal(config.apps[0].iconUrl, "/assets/step-icons/install-immich.svg");
  assert.equal(config.apps[0].iconAlt, "Immich icon");
  assert(config.adminApps.length > 0);
  assert(!config.apps.some((card) => card.title === "Grafana"));
});
