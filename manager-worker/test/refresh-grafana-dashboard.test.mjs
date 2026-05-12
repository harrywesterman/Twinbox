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
    installGrafanaStatus = "succeeded",
    dashboard = {
      templating: {
        list: [
          {
            name: "datasource",
            regex: "",
            current: {
              selected: false,
              text: "${datasource}",
              value: "${datasource}",
            },
          },
          {
            name: "job",
            current: {
              selected: false,
              text: "${VAR_JOB}",
              value: "${VAR_JOB}",
            },
          },
        ],
      },
      panels: [
        {
          datasource: "${DS_MK8S}",
          title: "Cluster overview",
          targets: [
            {
              expr: 'cluster_name="$cluster"',
            },
          ],
        },
      ],
    },
  } = options;

  const root = fs.mkdtempSync(path.join(os.tmpdir(), "grafana-refresh-test-"));
  const dataDir = path.join(root, "data");
  const binDir = path.join(root, "bin");
  const kubectlLog = path.join(root, "kubectl.log");
  const curlLog = path.join(root, "curl.log");
  const capturedDashboardFile = path.join(root, "captured-dashboard.json");
  const kubeconfigFile = path.join(root, "kubeconfig");

  fs.mkdirSync(path.join(dataDir, "clusters"), { recursive: true });
  fs.mkdirSync(path.join(dataDir, "step-state", "clusters", "cluster_test_instance"), {
    recursive: true,
  });
  fs.mkdirSync(binDir, { recursive: true });

  fs.writeFileSync(kubeconfigFile, "apiVersion: v1\nkind: Config\n", "utf8");
  fs.writeFileSync(
    path.join(dataDir, "clusters", "cluster_test.json"),
    JSON.stringify({
      id: "cluster_test",
      slug: "tst",
      dns_domain: "example.com",
      cluster_instance_id: "cluster_test_instance",
      created_at: "2026-01-01T00:00:00.000Z",
      updated_at: "2026-01-02T00:00:00.000Z",
    })
  );

  if (installGrafanaStatus) {
    fs.writeFileSync(
      path.join(dataDir, "step-state", "clusters", "cluster_test_instance", "install-grafana.json"),
      JSON.stringify({
        step_id: "install-grafana",
        status: installGrafanaStatus,
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
echo "kubectl $*" >> "${kubectlLog}"

if [[ " $* " == *" create configmap managed-kubernetes-overview-dashboard "* ]]; then
  for arg in "$@"; do
    if [[ "$arg" == --from-file=managed-kubernetes-overview.json=* ]]; then
      source_file="\${arg#--from-file=managed-kubernetes-overview.json=}"
      cp "$source_file" "${capturedDashboardFile}"
    fi
  done
  cat <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: managed-kubernetes-overview-dashboard
  namespace: monitoring
data:
  managed-kubernetes-overview.json: |
    {}
YAML
  exit 0
fi

if [[ " $* " == *" apply -f - "* ]]; then
  cat >/dev/null
  exit 0
fi

exit 0
`
  );

  writeExecutable(
    path.join(binDir, "curl"),
    `#!/bin/bash
set -euo pipefail
echo "curl $*" >> "${curlLog}"
cat <<'JSON'
${JSON.stringify(dashboard, null, 2)}
JSON
`
  );

  return {
    root,
    dataDir,
    binDir,
    kubectlLog,
    curlLog,
    capturedDashboardFile,
    kubeconfigFile,
  };
}

function runHelper({ dataDir, binDir, kubeconfigFile }, triggerStepId, overrides = {}) {
  const env = {
    ...process.env,
    PATH: `${binDir}:${process.env.PATH || ""}`,
    TWINBOX_KUBECONFIG_FILE: kubeconfigFile,
    REQUIRE_KUBECONFIG_ENV: "1",
    ...overrides.env,
  };

  const result = spawnSync(
    "node",
    [
      "scripts/manager/refresh-grafana-dashboard.mjs",
      "--manager-data-dir",
      dataDir,
      "--cluster-id",
      "cluster_test",
      "--cluster-instance-id",
      "cluster_test_instance",
      "--trigger-step-id",
      triggerStepId,
      "--namespace",
      "monitoring",
    ],
    {
      cwd: repoRoot,
      env,
      encoding: "utf8",
    }
  );

  return {
    status: result.status,
    stdout: result.stdout,
    stderr: result.stderr,
  };
}

test.skip("refresh-grafana-dashboard reconciles the managed overview dashboard after grafana is installed", () => {
  const workspace = setupWorkspace({ installGrafanaStatus: "succeeded" });
  const result = runHelper(workspace, "install-prometheus");

  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Refreshing managed-kubernetes-overview dashboard/);
  assert.match(result.stdout, /Grafana dashboard refresh complete/);
  assert.equal(fs.existsSync(workspace.kubectlLog), true);
  assert.equal(fs.existsSync(workspace.curlLog), true);
  assert.equal(fs.existsSync(workspace.capturedDashboardFile), true);

  const renderedDashboard = JSON.parse(fs.readFileSync(workspace.capturedDashboardFile, "utf8"));
  assert.equal(renderedDashboard.templating.list[0].regex, ".*");
  assert.deepEqual(renderedDashboard.templating.list[0].current, {
    selected: true,
    text: "Prometheus",
    value: "Prometheus",
  });
  assert.deepEqual(renderedDashboard.templating.list[1].current, {
    selected: false,
    text: "node-exporter",
    value: "node-exporter",
  });
  assert.equal(renderedDashboard.panels[0].datasource, "Prometheus");
  assert.equal(renderedDashboard.panels[0].targets[0].expr, 'cluster_name=~".*"');

  const kubectlLog = fs.readFileSync(workspace.kubectlLog, "utf8");
  assert.match(kubectlLog, /kubectl apply -f -/);
  assert.match(
    kubectlLog,
    /kubectl -n monitoring delete configmap kubernetes-overview-dashboard --ignore-not-found=true/
  );
  assert.match(
    kubectlLog,
    /kubectl -n monitoring create configmap managed-kubernetes-overview-dashboard/
  );
  assert.match(
    kubectlLog,
    /kubectl -n monitoring label configmap managed-kubernetes-overview-dashboard/
  );

  const curlLog = fs.readFileSync(workspace.curlLog, "utf8");
  assert.match(curlLog, /https:\/\/grafana\.com\/api\/dashboards\/24155\/revisions\/1\/download/);
});

test("refresh-grafana-dashboard skips before grafana is installed", () => {
  const workspace = setupWorkspace({ installGrafanaStatus: null });
  const result = runHelper(workspace, "install-prometheus");

  assert.equal(result.status, 0, result.stderr);
  assert.match(
    result.stdout,
    /Grafana dashboard refresh skipped: install-grafana is not installed yet/
  );
  assert.equal(fs.existsSync(workspace.kubectlLog), false);
  assert.equal(fs.existsSync(workspace.curlLog), false);
  assert.equal(fs.existsSync(workspace.capturedDashboardFile), false);
});
