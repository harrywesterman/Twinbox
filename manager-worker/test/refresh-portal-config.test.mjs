import test from "node:test";
import assert from "node:assert/strict";
import fs from "fs";
import os from "os";
import path from "path";
import { spawnSync } from "child_process";
import { fileURLToPath } from "url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

function writeExecutable(file, content) {
  fs.writeFileSync(file, content, "utf8");
  fs.chmodSync(file, 0o755);
}

function setupWorkspace(options = {}) {
  const {
    portalStepStatus = "succeeded",
    additionalStepStatuses = {},
    installedApplications = ["immich", "jitsi", "audiobookshelf"],
  } = options;
  const installedApplicationsJson = installedApplications
    .map((app) => `    { "metadata": { "name": "${app}" } }`)
    .join(",\n");
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "portal-refresh-test-"));
  const dataDir = path.join(root, "data");
  const binDir = path.join(root, "bin");
  const logFile = path.join(root, "kubectl.log");
  const capturedConfigFile = path.join(root, "captured-portal-config.json");

  fs.mkdirSync(path.join(dataDir, "clusters"), { recursive: true });
  fs.mkdirSync(path.join(dataDir, "step-state", "clusters", "cluster_test_instance"), {
    recursive: true,
  });
  fs.mkdirSync(binDir, { recursive: true });

  fs.writeFileSync(
    path.join(dataDir, "clusters", "cluster_test.json"),
    JSON.stringify({
      id: "cluster_test",
      slug: "tst",
      dns_domain: "example.com",
      cluster_instance_id: "cluster_test_instance",
      created_at: "2026-01-01T00:00:00.000Z",
      updated_at: "2026-01-01T00:00:00.000Z",
    })
  );

  fs.writeFileSync(
    path.join(
      dataDir,
      "step-state",
      "clusters",
      "cluster_test_instance",
      "install-twinbox-portal.json"
    ),
    JSON.stringify({
      step_id: "install-twinbox-portal",
      status: portalStepStatus,
      inputs: {},
      outputs: {},
      cluster_id: "cluster_test",
      cluster_instance_id: "cluster_test_instance",
    })
  );

  for (const [stepId, status] of Object.entries(additionalStepStatuses)) {
    fs.writeFileSync(
      path.join(dataDir, "step-state", "clusters", "cluster_test_instance", `${stepId}.json`),
      JSON.stringify({
        step_id: stepId,
        status,
        inputs: {},
        outputs: {},
        cluster_id: "cluster_test",
        cluster_instance_id: "cluster_test_instance",
      })
    );
  }

  writeExecutable(
    path.join(binDir, "kubectl"),
    `#!/bin/bash
set -euo pipefail
if [[ "\${REQUIRE_KUBECONFIG_ENV:-}" == "1" && -z "\${KUBECONFIG:-}" ]]; then
  echo "KUBECONFIG is required" >&2
  exit 42
fi
echo "kubectl $*" >> "${logFile}"

if [[ "$*" == *" create secret generic "* ]]; then
  for arg in "$@"; do
    if [[ "$arg" == --from-file=portal-config.json=* ]]; then
      source_file="\${arg#--from-file=portal-config.json=}"
      cp "$source_file" "${capturedConfigFile}"
    fi
  done
  cat <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: portal-config
  namespace: twinbox-portal
type: Opaque
data: {}
YAML
  exit 0
fi

if [[ "$*" == *"-n argocd get application -o json"* ]]; then
  cat <<'JSON'
{
  "items": [
${installedApplicationsJson}
  ]
}
JSON
  exit 0
fi

if [[ "$*" == *" apply -f -"* ]]; then
  cat >/dev/null
  exit 0
fi

exit 0
`
  );

  return { root, dataDir, binDir, logFile, capturedConfigFile };
}

test("refresh-portal-config renders the portal secret after install", () => {
  const { dataDir, binDir, logFile, capturedConfigFile } = setupWorkspace();
  const env = {
    ...process.env,
    PATH: `${binDir}:${process.env.PATH || ""}`,
    MANAGER_DATA_DIR: dataDir,
    WORKSPACE_ROOT: repoRoot,
  };

  const result = spawnSync(
    "node",
    [
      "manager-worker/src/refresh-portal-config.mjs",
      "--workspace-root",
      repoRoot,
      "--manager-data-dir",
      dataDir,
      "--cluster-id",
      "cluster_test",
      "--cluster-instance-id",
      "cluster_test_instance",
      "--trigger-step-id",
      "install-twinbox-portal",
    ],
    {
      cwd: repoRoot,
      env,
      encoding: "utf8",
    }
  );

  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.existsSync(logFile), true);
  assert.equal(fs.existsSync(capturedConfigFile), true);
  const logText = fs.readFileSync(logFile, "utf8");
  assert.match(logText, /kubectl -n twinbox-portal create secret generic portal-config/);
  assert.match(logText, /kubectl apply --validate=false -f .*portal-config-secret\.yaml/);
});

test("refresh-portal-config runs during portal install when self-triggered", () => {
  const { dataDir, binDir, logFile } = setupWorkspace({ portalStepStatus: "running" });
  const env = {
    ...process.env,
    PATH: `${binDir}:${process.env.PATH || ""}`,
    MANAGER_DATA_DIR: dataDir,
    WORKSPACE_ROOT: repoRoot,
  };

  const result = spawnSync(
    "node",
    [
      "manager-worker/src/refresh-portal-config.mjs",
      "--workspace-root",
      repoRoot,
      "--manager-data-dir",
      dataDir,
      "--cluster-id",
      "cluster_test",
      "--cluster-instance-id",
      "cluster_test_instance",
      "--trigger-step-id",
      "install-twinbox-portal",
    ],
    {
      cwd: repoRoot,
      env,
      encoding: "utf8",
    }
  );

  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.existsSync(logFile), true);
  const logText = fs.readFileSync(logFile, "utf8");
  assert.match(logText, /kubectl -n twinbox-portal create secret generic portal-config/);
  assert.match(logText, /kubectl apply --validate=false -f .*portal-config-secret\.yaml/);
});

test("refresh-portal-config includes installed app steps in the portal catalog", () => {
  const { dataDir, binDir, capturedConfigFile } = setupWorkspace({
    additionalStepStatuses: {
      "install-jitsi": "succeeded",
    },
  });
  const env = {
    ...process.env,
    PATH: `${binDir}:${process.env.PATH || ""}`,
    MANAGER_DATA_DIR: dataDir,
    WORKSPACE_ROOT: repoRoot,
    TWINBOX_KUBECONFIG_FILE: "/tmp/fake-kubeconfig",
    REQUIRE_KUBECONFIG_ENV: "1",
  };

  const result = spawnSync(
    "node",
    [
      "manager-worker/src/refresh-portal-config.mjs",
      "--workspace-root",
      repoRoot,
      "--manager-data-dir",
      dataDir,
      "--cluster-id",
      "cluster_test",
      "--cluster-instance-id",
      "cluster_test_instance",
      "--trigger-step-id",
      "install-twinbox-portal",
    ],
    {
      cwd: repoRoot,
      env,
      encoding: "utf8",
    }
  );

  assert.equal(result.status, 0, result.stderr);
  const renderedConfig = JSON.parse(fs.readFileSync(capturedConfigFile, "utf8"));
  assert.equal(
    renderedConfig.apps.some((card) => card.title === "Jitsi"),
    true
  );
});

test("refresh-portal-config hides apps that no longer exist in Argo CD", () => {
  const { dataDir, binDir, capturedConfigFile } = setupWorkspace({
    additionalStepStatuses: {
      "install-audiobookshelf": "succeeded",
      "install-immich": "succeeded",
      "install-jitsi": "succeeded",
    },
    installedApplications: ["jitsi"],
  });
  const env = {
    ...process.env,
    PATH: `${binDir}:${process.env.PATH || ""}`,
    MANAGER_DATA_DIR: dataDir,
    WORKSPACE_ROOT: repoRoot,
  };

  const result = spawnSync(
    "node",
    [
      "manager-worker/src/refresh-portal-config.mjs",
      "--workspace-root",
      repoRoot,
      "--manager-data-dir",
      dataDir,
      "--cluster-id",
      "cluster_test",
      "--cluster-instance-id",
      "cluster_test_instance",
      "--trigger-step-id",
      "install-twinbox-portal",
    ],
    {
      cwd: repoRoot,
      env,
      encoding: "utf8",
    }
  );

  assert.equal(result.status, 0, result.stderr);
  const renderedConfig = JSON.parse(fs.readFileSync(capturedConfigFile, "utf8"));
  assert.equal(
    renderedConfig.apps.some((card) => card.title === "Immich"),
    false
  );
  assert.equal(
    renderedConfig.apps.some((card) => card.title === "Audiobookshelf"),
    false
  );
  assert.equal(
    renderedConfig.apps.some((card) => card.title === "Jitsi"),
    true
  );
});
