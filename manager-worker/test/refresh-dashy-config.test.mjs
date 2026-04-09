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

function setupWorkspace() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "dashy-refresh-test-"));
  const dataDir = path.join(root, "data");
  const binDir = path.join(root, "bin");
  const logFile = path.join(root, "kubectl.log");

  fs.mkdirSync(path.join(dataDir, "clusters"), { recursive: true });
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
    }),
  );

  writeExecutable(
    path.join(binDir, "kubectl"),
    `#!/bin/bash
set -euo pipefail
echo "kubectl $*" >> "${logFile}"

if [[ "$*" == *" get configmap "* ]]; then
  exit 1
fi

if [[ "$*" == *" get deployment "* ]]; then
  exit 1
fi

if [[ "$*" == *" create configmap "* ]]; then
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
`,
  );

  return { root, dataDir, binDir, logFile };
}

function runRefresh(triggerStepId, overrides = {}) {
  const { root, dataDir, binDir, logFile } = setupWorkspace();
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
    "--workspace-root", repoRoot,
    "--manager-data-dir", dataDir,
    "--cluster-id", "cluster_test",
    "--trigger-step-id", triggerStepId,
    "--cluster-instance-id", "cluster_test_instance",
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
    status: result.status,
    stdout: result.stdout,
    stderr: result.stderr,
  };
}

test("refresh-dashy-config skips pre-dashboard steps without Dashy items", () => {
  const result = runRefresh("provision-nodes");

  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Dashy refresh skipped: provision-nodes ran before Dashy was installed/);
  assert.equal(fs.existsSync(result.logFile), false);
});

test("refresh-dashy-config bootstraps Dashy on install-dashy-dashboard", () => {
  const result = runRefresh("install-dashy-dashboard");

  assert.equal(result.status, 0, result.stderr);
  assert.doesNotMatch(result.stdout, /Dashy refresh skipped/);
  assert.equal(fs.existsSync(result.logFile), true);

  const logText = fs.readFileSync(result.logFile, "utf8");
  assert.match(logText, /kubectl apply -f -/);
  assert.match(logText, /kubectl -n dashy create configmap dashy-config/);
});
