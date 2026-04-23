import test from "node:test";
import assert from "node:assert/strict";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

import YAML from "yaml";

import { normalizeStepManifest } from "../../lib/step-manifest.mjs";
import { buildDashyConfig } from "../../lib/dashy-config.mjs";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

function loadStep(stepId) {
  const file = path.join(repoRoot, "categories", "talos-cluster", "steps", stepId, "step.yaml");
  const manifest = YAML.parse(fs.readFileSync(file, "utf8"));
  return normalizeStepManifest(manifest, file, "talos-cluster");
}

test("real step manifests normalize Dashy metadata", () => {
  const step = loadStep("install-management-consoles");

  assert.equal(step.dashy.items.length, 3);
  assert.deepEqual(
    step.dashy.items.map((item) => item.title),
    ["Proxmox", "SeaweedFS", "SeaweedFS Admin"],
  );
});

test("buildDashyConfig renders fixed, static, dynamic, and multi-item entries", () => {
  const steps = [
    loadStep("provision-nodes"),
    loadStep("install-argocd"),
    loadStep("install-authentik-idp"),
    loadStep("install-grafana"),
    loadStep("install-prometheus"),
    loadStep("install-loki"),
    loadStep("install-management-consoles"),
    loadStep("install-pgadmin4"),
    loadStep("install-twinbox-portal"),
    loadStep("install-velero-ui"),
    loadStep("install-wiredoor-gateway"),
  ];

  const stepStateById = new Map([
    ["provision-nodes", { status: "succeeded", outputs: {} }],
    ["install-argocd", { status: "succeeded", outputs: {} }],
    ["install-authentik-idp", { status: "succeeded", outputs: {} }],
    ["install-grafana", { status: "succeeded", outputs: {} }],
    ["install-prometheus", { status: "succeeded", outputs: {} }],
    ["install-loki", { status: "succeeded", outputs: {} }],
    ["install-management-consoles", { status: "succeeded", outputs: {} }],
    ["install-pgadmin4", { status: "succeeded", outputs: {} }],
    ["install-twinbox-portal", { status: "succeeded", outputs: {} }],
    ["install-velero-ui", { status: "succeeded", outputs: {} }],
    ["install-wiredoor-gateway", { status: "succeeded", outputs: { wiredoor_url: "https://wiredoor.example.net" } }],
  ]);

  const config = buildDashyConfig({
    steps,
    stepStateById,
    cluster: {
      id: "tst",
      slug: "tst",
      dns_domain: "example.com",
      cluster_instance_id: "tst-1",
    },
  });

  const platformSection = config.sections.find((section) => section.name === "Platform");
  assert(platformSection, "expected Platform section");
  assert.deepEqual(platformSection.displayData, { sortBy: "alphabetical" });

  assert(platformSection.items.some((item) => item.title === "Hubble" && item.url === "https://hubble.tst.example.com"));
  assert(platformSection.items.some((item) => item.title === "Argo CD" && item.url === "https://argocd.tst.example.com"));
  assert(platformSection.items.some((item) => item.title === "Authentik" && item.url === "https://authentik.tst.example.com"));
  assert(platformSection.items.some((item) => item.title === "Grafana" && item.url === "https://grafana.tst.example.com"));
  assert(platformSection.items.some((item) => item.title === "Loki" && item.url === "https://grafana.tst.example.com/explore"));
  assert(platformSection.items.some((item) => item.title === "SeaweedFS Admin" && item.url === "https://seaweedfs-admin.tst.example.com"));
  assert(platformSection.items.some((item) => item.title === "Twinbox Portal" && item.url === "https://portal.tst.example.com"));
  assert(platformSection.items.some((item) => item.title === "Velero UI" && item.url === "https://velero-ui.tst.example.com"));
  assert(platformSection.items.some((item) => item.title === "pgAdmin 4" && item.url === "https://pgadmin4.tst.example.com"));
  assert(platformSection.items.some((item) => item.title === "Wiredoor" && item.url === "https://wiredoor.example.net"));
  assert(platformSection.items.some((item) => item.title === "Cloudflare" && item.url === "https://dash.cloudflare.com/"));
  assert(platformSection.items.some((item) => item.title === "GitHub" && item.url === "https://github.com/harrywesterman/Twinbox"));

  const iconByTitle = new Map(config.sections.flatMap((section) => section.items.map((item) => [item.title, item.icon])));
  const wizardIconBase = "https://twinboxwizard.tst.example.com/assets/step-icons";
  assert.equal(iconByTitle.get("Hubble"), `${wizardIconBase}/provision-nodes.svg`);
  assert.equal(iconByTitle.get("Argo CD"), `${wizardIconBase}/install-argocd.svg`);
  assert.equal(iconByTitle.get("Authentik"), `${wizardIconBase}/install-authentik-idp.svg`);
  assert.equal(iconByTitle.get("Grafana"), `${wizardIconBase}/install-grafana.svg`);
  assert.equal(iconByTitle.get("Prometheus"), `${wizardIconBase}/install-prometheus.svg`);
  assert.equal(iconByTitle.get("Loki"), `${wizardIconBase}/install-loki.svg`);
  assert.equal(iconByTitle.get("Proxmox"), `${wizardIconBase}/install-proxmox-backup-system.svg`);
  assert.equal(iconByTitle.get("SeaweedFS"), `${wizardIconBase}/install-management-consoles.svg`);
  assert.equal(iconByTitle.get("SeaweedFS Admin"), `${wizardIconBase}/install-management-consoles.svg`);
  assert.equal(iconByTitle.get("Twinbox Portal"), `${wizardIconBase}/install-twinbox-portal.svg`);
  assert.equal(iconByTitle.get("Velero UI"), `${wizardIconBase}/install-velero-ui.svg`);
  assert.equal(iconByTitle.get("pgAdmin 4"), `${wizardIconBase}/install-pgadmin4.svg`);
  assert.equal(iconByTitle.get("Wiredoor"), `${wizardIconBase}/install-wiredoor-gateway.svg`);
  assert.equal(iconByTitle.get("Cloudflare"), `${wizardIconBase}/configure-cloudflare-dns.svg`);
  assert.equal(iconByTitle.get("GitHub"), `${wizardIconBase}/github.svg`);

  assert.equal(config.appConfig.faviconApi, "local");
  assert.equal(config.appConfig.iconSize, "large");
  assert.equal(config.appConfig.layout, "vertical");
  assert.equal(config.appConfig.theme, "nord-frost");
  assert.equal(config.pageInfo.title, "Admin");
  assert.equal(config.pageInfo.description, "Twinbox Admin start pagina");
});

test("buildDashyConfig hides steps that are not completed", () => {
  const steps = [
    loadStep("provision-nodes"),
    loadStep("install-pgadmin4"),
  ];

  const stepStateById = new Map([
    ["provision-nodes", { status: "failed", outputs: {} }],
    ["install-pgadmin4", { status: "skipped", outputs: {} }],
  ]);

  const config = buildDashyConfig({
    steps,
    stepStateById,
    cluster: {
      id: "tst",
      slug: "tst",
      dns_domain: "example.com",
      cluster_instance_id: "tst-1",
    },
  });

  const titles = config.sections.flatMap((section) => section.items.map((item) => item.title));
  assert(!titles.includes("Hubble"));
  assert(!titles.includes("pgAdmin 4"));
  assert(titles.includes("Cloudflare"));
  assert(titles.includes("GitHub"));
});

test("buildDashyConfig skips zone-based URLs until the public zone is known", () => {
  const steps = [loadStep("provision-nodes")];
  const stepStateById = new Map([
    ["provision-nodes", { status: "succeeded", outputs: {} }],
  ]);

  const config = buildDashyConfig({
    steps,
    stepStateById,
    cluster: {
      id: "tst",
      slug: "tst",
      dns_domain: "",
      cluster_instance_id: "tst-1",
    },
  });

  const platformSection = config.sections.find((section) => section.name === "Platform");
  assert(platformSection, "expected Platform section");
  assert(!platformSection.items.some((item) => item.title === "Hubble"));
  assert(platformSection.items.some((item) => item.title === "Cloudflare"));
  assert(platformSection.items.some((item) => item.title === "GitHub"));
});

test("normalizeStepManifest rejects Dashy items with conflicting URL sources", () => {
  const file = path.join(repoRoot, "categories", "talos-cluster", "steps", "install-pgadmin4", "step.yaml");
  const manifest = YAML.parse(fs.readFileSync(file, "utf8"));
  manifest.dashy.items[0].output_url_key = "access_url";

  assert.throws(
    () => normalizeStepManifest(manifest, file, "talos-cluster"),
    /must not define both url_template and output_url_key/,
  );
});
