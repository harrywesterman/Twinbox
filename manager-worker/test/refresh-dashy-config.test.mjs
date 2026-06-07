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
  const { stepStatuses = {} } = options;
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "dashy-refresh-test-"));
  const dataDir = path.join(root, "data");
  const binDir = path.join(root, "bin");
  const logFile = path.join(root, "kubectl.log");
  const capturedConfigFile = path.join(root, "captured-dashy-config.yml");

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

  for (const [stepId, status] of Object.entries(stepStatuses)) {
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

if [[ "$*" == *" get configmap "* ]]; then
  exit 1
fi

if [[ "$*" == *" get deployment "* ]]; then
  exit 1
fi

if [[ "$*" == *" create configmap "* ]]; then
  for arg in "$@"; do
    if [[ "$arg" == --from-file=conf.yml.tpl=* ]]; then
      source_file="\${arg#--from-file=conf.yml.tpl=}"
      cp "$source_file" "${capturedConfigFile}"
    fi
  done
  cat <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: dashy-config
  namespace: dashy
data:
  conf.yml.tpl: |
    pageInfo:
      title: Start
      description: Twinbox cluster start page
YAML
  exit 0
fi

if [[ "$*" == *" apply -f -"* ]]; then
  cat >/dev/null
  exit 0
fi

if [[ "$*" == *" rollout restart "* || "$*" == *" rollout status "* ]]; then
  exit 0
fi

exit 0
`
  );

  return { root, dataDir, binDir, logFile, capturedConfigFile };
}

function runRefresh(triggerStepId, overrides = {}) {
  const { root, dataDir, binDir, logFile, capturedConfigFile } = setupWorkspace({
    stepStatuses: overrides.stepStatuses || {},
  });
  const env = {
    ...process.env,
    PATH: `${binDir}:${process.env.PATH || ""}`,
    MANAGER_DATA_DIR: dataDir,
    WORKSPACE_ROOT: repoRoot,
  };
  if (overrides.env) {
    Object.assign(env, overrides.env);
  }

  const args = [
    "manager-worker/src/refresh-dashy-config.mjs",
    "--workspace-root",
    repoRoot,
    "--manager-data-dir",
    dataDir,
    "--cluster-id",
    "cluster_test",
    "--trigger-step-id",
    triggerStepId,
    "--cluster-instance-id",
    "cluster_test_instance",
  ];

  const result = spawnSync("node", args, {
    cwd: repoRoot,
    env,
    encoding: "utf8",
  });

  return {
    root,
    dataDir,
    logFile,
    capturedConfigFile,
    status: result.status,
    stdout: result.stdout,
    stderr: result.stderr,
  };
}

test("refresh-dashy-config skips pre-dashboard steps without Dashy items", () => {
  const result = runRefresh("provision-nodes");

  assert.equal(result.status, 0, result.stderr);
  assert.match(
    result.stdout,
    /Dashy refresh skipped: provision-nodes ran before Dashy was installed/
  );
  assert.equal(fs.existsSync(result.logFile), false);
});

test("refresh-dashy-config skips App Installs steps", () => {
  const result = runRefresh("install-jitsi");

  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Dashy refresh skipped: install-jitsi is a user app install/);
  assert.equal(fs.existsSync(result.logFile), false);
});
