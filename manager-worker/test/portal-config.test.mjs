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

test("buildPortalConfig keeps operator tools out of the user applications grid and carries mobile links", () => {
  const steps = [
    loadStep("install-grafana"),
    loadStep("install-headlamp"),
    loadStep("install-management-consoles"),
    loadStep("install-dashy-dashboard"),
    loadStep("install-velero-ui"),
    loadAppStep("install-opencloud"),
    loadAppStep("install-immich"),
    loadAppStep("install-audiobookshelf"),
  ];

  const stepStateById = new Map([
    ["install-grafana", { status: "succeeded" }],
    ["install-headlamp", { status: "succeeded" }],
    ["install-management-consoles", { status: "succeeded" }],
    ["install-dashy-dashboard", { status: "succeeded" }],
    ["install-velero-ui", { status: "configured" }],
    ["install-opencloud", { status: "succeeded" }],
    ["install-immich", { status: "succeeded" }],
    ["install-audiobookshelf", { status: "succeeded" }],
  ]);

  const config = buildPortalConfig({
    steps,
    stepStateById,
    cluster: {
      id: "tst",
      slug: "tst",
      dns_domain: "example.com",
    },
    content: JSON.parse(
      fs.readFileSync(path.join(repoRoot, "config", "portal", "content.json"), "utf8")
    ),
  });

  assert.equal(config.portal.brand, "Twinbox");
  assert.equal(
    config.settings.issueUrl,
    "https://github.com/harrywesterman/Twinbox/issues/new/choose"
  );
  assert.equal(config.userAdmin.title, "Gebruikers en groepen");
  assert.deepEqual(config.userAdmin.manageableGroups, []);
  assert.equal(config.settings.authentikAdminUrl, "https://authentik.tst.example.com/if/admin/");
  assert.equal(
    config.settings.authentikUserUrl,
    'https://authentik.tst.example.com/if/user/#/settings;{"page":"page-details"}'
  );
  assert.equal(
    config.settings.authentikOtpUrl,
    'https://authentik.tst.example.com/if/user/#/settings;{"page":"page-credentials","ak-user-settings-mfa-page":0}'
  );
  assert.equal(config.observability.title, "Observability control");
  assert.equal(config.observability.profiles.minimal.summary, "Small-cluster mode");
  assert.equal(config.observability.profiles.off.priority, "destructive");
  assert.deepEqual(
    config.apps.map((card) => card.title),
    ["Audiobookshelf", "Immich", "OpenCloud"]
  );
  assert.equal(config.appSections.length, 1);
  assert.equal(config.appSections[0].name, "Apps");
  assert.deepEqual(
    config.appSections[0].items.map((card) => card.title),
    ["Audiobookshelf", "Immich", "OpenCloud"]
  );
  assert.deepEqual(config.apps.find((card) => card.title === "Immich")?.mobileLinks, [
    {
      platform: "iPhone",
      label: "App Store",
      url: "https://apps.apple.com/us/app/immich/id1613945652",
    },
    {
      platform: "Android",
      label: "Google Play",
      url: "https://play.google.com/store/apps/details?id=app.alextran.immich",
    },
  ]);
  assert.deepEqual(config.apps.find((card) => card.title === "OpenCloud")?.mobileLinks, [
    {
      platform: "iPhone",
      label: "App Store",
      url: "https://apps.apple.com/us/app/opencloud-your-data-anywhere/id6743121005",
    },
    {
      platform: "Android",
      label: "Google Play",
      url: "https://play.google.com/store/apps/details?id=eu.opencloud.android",
    },
  ]);
  assert.deepEqual(config.apps.find((card) => card.title === "Audiobookshelf")?.mobileLinks, []);
  assert(config.adminApps.some((card) => card.title === "Dashy"));
  assert.equal(config.adminApps.find((card) => card.title === "Dashy")?.label, "Open Admin tools");
  assert.equal(
    config.adminApps.find((card) => card.title === "Dashy")?.iconUrl,
    "/assets/step-icons/install-dashy-dashboard.svg"
  );
  assert.equal(
    config.intranetLinks.map((card) => card.title).join(", "),
    "Cluster status, Documentation, GitHub"
  );
  assert.equal(
    config.intranetLinks.find((card) => card.title === "GitHub")?.iconUrl,
    "/assets/step-icons/github.svg"
  );
  assert.equal(
    config.intranetLinks.find((card) => card.title === "Cluster status")?.iconUrl,
    "/assets/step-icons/cluster-status.svg"
  );
  assert.equal(
    config.intranetLinks.find((card) => card.title === "Documentation")?.iconUrl,
    "/assets/step-icons/support-docs.svg"
  );
  assert(config.statusChecks.some((card) => card.title === "Authentik"));
  assert(config.apps.every((card) => card.liveUrl.startsWith("https://")));
});

test("buildPortalConfig shows user apps only after the app category is installed", () => {
  const steps = [loadStep("install-grafana"), loadAppStep("install-immich")];
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
    content: JSON.parse(
      fs.readFileSync(path.join(repoRoot, "config", "portal", "content.json"), "utf8")
    ),
  });

  assert.deepEqual(
    config.apps.map((card) => card.title),
    ["Immich"]
  );
  assert.equal(config.appSections.length, 1);
  assert.equal(config.appSections[0].name, "Apps");
  assert.deepEqual(
    config.appSections[0].items.map((card) => card.title),
    ["Immich"]
  );
  assert.equal(config.apps[0].iconUrl, "/assets/step-icons/install-immich.svg");
  assert.equal(config.apps[0].iconAlt, "Immich icon");
  assert(config.adminApps.length > 0);
  assert(!config.apps.some((card) => card.title === "Grafana"));
});
