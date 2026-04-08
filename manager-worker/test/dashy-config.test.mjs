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

  assert.equal(step.dashy.items.length, 4);
  assert.deepEqual(
    step.dashy.items.map((item) => item.title),
    ["Twinbox Wizard", "Proxmox", "SeaweedFS", "SeaweedFS Admin"],
  );
});

test("buildDashyConfig renders fixed, static, dynamic, and multi-item entries", () => {
  const steps = [
    loadStep("provision-nodes"),
    loadStep("install-authentik-idp"),
    loadStep("install-management-consoles"),
    loadStep("install-cloudtty"),
    loadStep("install-whoami"),
  ];

  const stepStateById = new Map([
    ["provision-nodes", { status: "succeeded", outputs: {} }],
    ["install-authentik-idp", { status: "succeeded", outputs: {} }],
    ["install-management-consoles", { status: "succeeded", outputs: {} }],
    ["install-cloudtty", { status: "succeeded", outputs: { access_url: "https://shell.example.net" } }],
    ["install-whoami", { status: "configured", outputs: {} }],
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
  const appsSection = config.sections.find((section) => section.name === "Apps");
  assert(platformSection, "expected Platform section");
  assert(appsSection, "expected Apps section");

  assert(platformSection.items.some((item) => item.title === "Hubble" && item.url === "https://hubble.tst.example.com"));
  assert(platformSection.items.some((item) => item.title === "Authentik" && item.url === "https://authentik.tst.example.com"));
  assert(platformSection.items.some((item) => item.title === "Twinbox Wizard" && item.url === "https://twinboxwizard.tst.example.com"));
  assert(platformSection.items.some((item) => item.title === "SeaweedFS Admin" && item.url === "https://seaweedfs-admin.tst.example.com"));
  assert(platformSection.items.some((item) => item.title === "Cloudtty" && item.url === "https://shell.example.net"));
  assert(platformSection.items.some((item) => item.title === "Cloudflare" && item.url === "https://dash.cloudflare.com/"));
  assert(platformSection.items.some((item) => item.title === "GitHub" && item.url === "https://github.com/harrywesterman/Twinbox"));
  assert(appsSection.items.some((item) => item.title === "Whoami" && item.url === "https://whoami.tst.example.com"));

  for (const section of config.sections) {
    for (const item of section.items) {
      assert.notEqual(item.icon, "");
    }
  }
});

test("buildDashyConfig hides steps that are not completed", () => {
  const steps = [
    loadStep("provision-nodes"),
    loadStep("install-cloudtty"),
    loadStep("install-whoami"),
  ];

  const stepStateById = new Map([
    ["provision-nodes", { status: "failed", outputs: {} }],
    ["install-cloudtty", { status: "skipped", outputs: { access_url: "https://shell.example.net" } }],
    ["install-whoami", { status: "not_started", outputs: {} }],
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
  assert(!titles.includes("Cloudtty"));
  assert(!titles.includes("Whoami"));
  assert(titles.includes("Cloudflare"));
  assert(titles.includes("GitHub"));
});

test("normalizeStepManifest rejects Dashy items with conflicting URL sources", () => {
  const file = path.join(repoRoot, "categories", "talos-cluster", "steps", "install-whoami", "step.yaml");
  const manifest = YAML.parse(fs.readFileSync(file, "utf8"));
  manifest.dashy.items[0].output_url_key = "access_url";

  assert.throws(
    () => normalizeStepManifest(manifest, file, "talos-cluster"),
    /must not define both url_template and output_url_key/,
  );
});
