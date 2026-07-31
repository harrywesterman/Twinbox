import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

function read(relativePath) {
  return fs.readFileSync(path.join(repoRoot, relativePath), "utf8");
}

test("Headwind MDM exposes an optional app, private console and enrollment-only route", () => {
  const step = read("categories/apps/steps/install-headwind-mdm/step.yaml");
  const applicationSet = read("gitops/optional-apps/headwind-mdm.yaml");
  const ingress = read("gitops/platform-apps/headwind-mdm/templates/ingressroute.yaml");

  assert.match(step, /id: install-headwind-mdm/);
  assert.match(step, /mdm-admin\.__ZONE_NAME__/);
  assert.match(applicationSet, /twinbox\.io\/app-headwind-mdm: "enabled"/);
  assert.match(applicationSet, /path: gitops\/databases\/headwind-mdm/);
  assert.match(ingress, /PathPrefix\(`\/rest\/public\/`\)/);
  assert.match(ingress, /PathPrefix\(`\/files\/`\)/);
  assert.doesNotMatch(ingress, /PathPrefix\(`\/rest\/private\//);
});

test("Headwind catalog pins and verifies the managed Android artifacts", () => {
  const catalog = read("gitops/platform-apps/headwind-mdm/templates/catalog-configmap.yaml");
  const reconciler = read("gitops/platform-apps/headwind-mdm/files/reconcile.mjs");

  assert.match(catalog, /io\.netbird\.client/);
  assert.match(catalog, /org\.mozilla\.fennec_fdroid/);
  assert.match(catalog, /c2f2ef6bc6aece879383e5800090b75f04398464af33c4ba0c1d133243bc32ea/);
  assert.match(catalog, /5e60a0abc611aab42b79737a2d2beb9ec712de98e75b82dfceadacda29e93d9f/);
  assert.match(reconciler, /verifyArtifact/);
  assert.match(reconciler, /io\.twinbox\.mobile\.web\./);
  assert.match(reconciler, /pushOptions: "polling"/);
});

test("Headwind wrapper receives its documented SQL, TLS and variant settings", () => {
  const deployment = read("gitops/platform-apps/headwind-mdm/templates/deployment.yaml");
  const internalTls = read("gitops/platform-apps/headwind-mdm/templates/internal-tls.yaml");

  assert.match(deployment, /name: HMDM_VARIANT/);
  assert.match(deployment, /name: SQL_PORT/);
  assert.match(deployment, /name: SQL_PASS/);
  assert.match(deployment, /name: HTTPS_CERT_PATH/);
  assert.match(deployment, /secretName: headwind-mdm-internal-tls/);
  assert.match(internalTls, /kind: Certificate/);
  assert.match(internalTls, /kind: Issuer/);
});
