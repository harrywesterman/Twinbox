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
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "portal-refresh-test-"));
  const dataDir = path.join(root, "data");
  const binDir = path.join(root, "bin");
  const logFile = path.join(root, "kubectl.log");

  fs.mkdirSync(path.join(dataDir, "clusters"), { recursive: true });
  fs.mkdirSync(path.join(dataDir, "step-state", "clusters", "cluster_test"), { recursive: true });
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

  fs.writeFileSync(
    path.join(dataDir, "step-state", "clusters", "cluster_test", "install-twinbox-portal.json"),
    JSON.stringify({
      step_id: "install-twinbox-portal",
      status: "succeeded",
      inputs: {},
      outputs: {},
      cluster_id: "cluster_test",
      cluster_instance_id: "cluster_test_instance",
    }),
  );

  writeExecutable(
    path.join(binDir, "kubectl"),
    `#!/bin/bash
set -euo pipefail
echo "kubectl $*" >> "${logFile}"

if [[ "$*" == *" create configmap "* ]]; then
  cat <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: portal-config
  namespace: twinbox-portal
data:
  portal-config.json: |
    {}
YAML
  exit 0
fi

if [[ "$*" == *" apply -f -"* ]]; then
  cat >/dev/null
  exit 0
fi

exit 0
`,
  );

  return { root, dataDir, binDir, logFile };
}

test("refresh-portal-config renders the portal configmap after install", () => {
  const { dataDir, binDir, logFile } = setupWorkspace();
  const env = {
    ...process.env,
    PATH: `${binDir}:${process.env.PATH || ""}`,
    MANAGER_DATA_DIR: dataDir,
    WORKSPACE_ROOT: repoRoot,
  };

  const result = spawnSync("node", [
    "manager-worker/src/refresh-portal-config.mjs",
    "--workspace-root", repoRoot,
    "--manager-data-dir", dataDir,
    "--cluster-id", "cluster_test",
    "--cluster-instance-id", "cluster_test_instance",
    "--trigger-step-id", "install-twinbox-portal",
  ], {
    cwd: repoRoot,
    env,
    encoding: "utf8",
  });

  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.existsSync(logFile), true);
  const logText = fs.readFileSync(logFile, "utf8");
  assert.match(logText, /kubectl -n twinbox-portal create configmap portal-config/);
});
