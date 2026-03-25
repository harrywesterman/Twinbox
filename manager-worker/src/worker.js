import fs from "fs";
import path from "path";
import { spawn, spawnSync } from "child_process";
import { createSecretBroker } from "../../lib/secrets/broker.mjs";
import { buildRedactor } from "../../lib/secrets/redact.mjs";
import {
  buildClusterWorkerSecretBundle,
} from "../../lib/secrets/schema.mjs";

const dataRoot = process.env.MANAGER_DATA_DIR || "/data";
const workspace = process.env.WORKSPACE_ROOT || "/opt/twinbox";
const pollMs = Number(process.env.WORKER_POLL_MS || 2000);
const secretBroker = createSecretBroker(process.env);

const dirs = {
  clusters: path.join(dataRoot, "clusters"),
  jobs: path.join(dataRoot, "jobs"),
  logs: path.join(dataRoot, "logs"),
  pending: path.join(dataRoot, "queue", "pending"),
  running: path.join(dataRoot, "queue", "running"),
  completed: path.join(dataRoot, "queue", "completed"),
  stepState: path.join(dataRoot, "step-state"),
  stepResults: path.join(dataRoot, "step-results"),
};

Object.values(dirs).forEach((dir) => fs.mkdirSync(dir, { recursive: true }));

function now() {
  return new Date().toISOString();
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(value, null, 2));
}

function updateJob(jobId, patch) {
  const file = path.join(dirs.jobs, `${jobId}.json`);
  const job = readJson(file);
  const merged = { ...job, ...patch, updated_at: now() };
  writeJson(file, merged);
  return merged;
}

function appendLog(jobId, message) {
  fs.appendFileSync(path.join(dirs.logs, `${jobId}.log`), `[${now()}] ${message}\n`);
}

function summarizeFailureOutput(lines, fallbackMessage) {
  const cleaned = (lines || [])
    .map((line) => String(line || "").trim())
    .filter(Boolean)
    .filter((line) => !line.startsWith("exec: "))
    .filter((line) => !line.startsWith("running job type="))
    .filter((line) => !line.startsWith("queued "))
    .filter((line) => !line.startsWith("job failed:"))
    .filter((line) => !line.startsWith("job completed"));

  if (cleaned.length === 0) {
    return fallbackMessage;
  }

  const recent = cleaned.slice(-3).join(" | ");
  return `${fallbackMessage}: ${recent}`;
}

function readJsonIfExists(file) {
  if (!fs.existsSync(file)) {
    return null;
  }
  return readJson(file);
}

function readStepState(stepId) {
  return readJsonIfExists(path.join(dirs.stepState, `${stepId}.json`));
}

function updateStepState(stepId, patch) {
  const file = path.join(dirs.stepState, `${stepId}.json`);
  const current = readStepState(stepId) || {
    step_id: stepId,
    status: "not_started",
    inputs: {},
    outputs: null,
    cluster_id: null,
    error: null,
    last_job_id: null,
    created_at: now(),
  };
  const next = {
    ...current,
    ...patch,
    step_id: stepId,
    updated_at: now(),
  };
  writeJson(file, next);
  return next;
}

function runCommand(jobId, command, args, env = {}, redactLine = (line) => String(line ?? ""), stripEnv = []) {
  return new Promise((resolve, reject) => {
    appendLog(jobId, `exec: ${command} ${args.join(" ")}`);
    const recentOutput = [];
    const recordChunk = (chunk) => {
      const text = chunk.toString();
      for (const line of text.split(/\r?\n/)) {
        const trimmed = line.trimEnd();
        if (!trimmed) continue;
        const redacted = redactLine(trimmed);
        recentOutput.push(redacted);
        if (recentOutput.length > 20) {
          recentOutput.shift();
        }
        appendLog(jobId, redacted);
      }
    };

    const childEnv = { ...process.env, ...env };
    for (const name of stripEnv) {
      delete childEnv[name];
    }

    const child = spawn(command, args, {
      cwd: workspace,
      env: childEnv,
      stdio: ["ignore", "pipe", "pipe"],
    });

    child.stdout.on("data", recordChunk);
    child.stderr.on("data", recordChunk);

    child.on("error", (err) => reject(err));
    child.on("close", (code) => {
      if (code === 0) {
        resolve();
      } else {
        reject(new Error(summarizeFailureOutput(recentOutput, `command exited with code ${code}`)));
      }
    });
  });
}

function emptySecretRuntime() {
  return {
    env: {},
    files: {},
    redactions: [],
    strip_env: [],
    cleanup() {},
  };
}

function resolveJobSecretRuntime(payload, clusterId = null) {
  const cluster = payload?.context?.cluster || payload;
  const secretBundle = payload?.secret_bundle
    || (cluster?.metadata ? buildClusterWorkerSecretBundle(cluster) : null);

  if (!secretBundle) {
    return emptySecretRuntime();
  }

  const runtime = secretBroker.resolveBundle(secretBundle, {
    clusterId: clusterId || cluster?.id || payload?.cluster_id || null,
  });
  const envKeys = Object.keys(secretBundle.env || {});

  return {
    ...runtime,
    strip_env: envKeys.includes("TF_VAR_proxmox_password") && !envKeys.includes("PROXMOX_PASSWORD")
      ? ["PROXMOX_PASSWORD"]
      : [],
  };
}

function requireEnv(name) {
  const value = process.env[name];
  if (!value || value.trim() === "") {
    throw new Error(`missing required environment variable: ${name}`);
  }
  return value.trim();
}

function loadPinnedDefaults() {
  const file = path.join(workspace, "config", "pinned-defaults.sh");
  if (!fs.existsSync(file)) {
    throw new Error(`pinned defaults file not found: ${file}`);
  }

  const values = {};
  for (const rawLine of fs.readFileSync(file, "utf8").split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const [key, ...rest] = line.split("=");
    if (!key || rest.length === 0) continue;
    values[key.trim()] = rest.join("=").trim();
  }

  if (!values.PINNED_TALOS_VERSION) {
    throw new Error(`missing PINNED_TALOS_VERSION in ${file}`);
  }
  if (!values.PINNED_OPENTOFU_VERSION) {
    throw new Error(`missing PINNED_OPENTOFU_VERSION in ${file}`);
  }

  return values;
}

function normalizeVersion(value) {
  return value.trim().replace(/^v/, "");
}

function extractSemver(value, label) {
  const match = value.match(/v?(\d+\.\d+\.\d+)/);
  if (!match) {
    throw new Error(`failed to parse ${label} version from output: ${value}`);
  }
  return match[1];
}

function runVersionCommand(command, args) {
  const result = spawnSync(command, args, { encoding: "utf8" });
  if (result.error) {
    throw new Error(`${command} failed: ${result.error.message}`);
  }
  if (result.status !== 0) {
    const stderr = (result.stderr || "").trim();
    throw new Error(`${command} ${args.join(" ")} exited with code ${result.status}${stderr ? `: ${stderr}` : ""}`);
  }
  const output = `${result.stdout || ""}\n${result.stderr || ""}`.trim();
  return output;
}

function ensureToolVersionsMatchPolicy() {
  const pinnedDefaults = loadPinnedDefaults();
  const expectedTalosctl = normalizeVersion(pinnedDefaults.PINNED_TALOS_VERSION);
  const expectedTofu = normalizeVersion(pinnedDefaults.PINNED_OPENTOFU_VERSION);
  const expectedKubectl = normalizeVersion(requireEnv("KUBECTL_VERSION"));
  const expectedHelm = normalizeVersion(requireEnv("HELM_VERSION"));

  const talosOutput = runVersionCommand("talosctl", ["version", "--client"]);
  const tofuOutput = runVersionCommand("tofu", ["version"]);
  const kubectlOutput = runVersionCommand("kubectl", ["version", "--client", "--output=json"]);
  const helmOutput = runVersionCommand("helm", ["version", "--short"]);

  const talosActual = extractSemver(talosOutput, "talosctl");
  const tofuActual = extractSemver(tofuOutput, "tofu");
  const kubectlActual = extractSemver(kubectlOutput, "kubectl");
  const helmActual = extractSemver(helmOutput, "helm");

  const mismatches = [];
  if (talosActual !== expectedTalosctl) {
    mismatches.push(`talosctl expected v${expectedTalosctl}, got v${talosActual}`);
  }
  if (tofuActual !== expectedTofu) {
    mismatches.push(`tofu expected v${expectedTofu}, got v${tofuActual}`);
  }
  if (kubectlActual !== expectedKubectl) {
    mismatches.push(`kubectl expected v${expectedKubectl}, got v${kubectlActual}`);
  }
  if (helmActual !== expectedHelm) {
    mismatches.push(`helm expected v${expectedHelm}, got v${helmActual}`);
  }

  if (mismatches.length > 0) {
    throw new Error(`tool version mismatch: ${mismatches.join("; ")}`);
  }
}

async function handleApply(job) {
  const cluster = job.payload;
  const dnsServers = Array.isArray(cluster.dns_servers) ? cluster.dns_servers.join(",") : String(cluster.dns_servers || "");
  const secretRuntime = resolveJobSecretRuntime(cluster, cluster.id);
  const redact = buildRedactor(secretRuntime.redactions);

  try {
    await runCommand(
      job.id,
      "bash",
      [
        "scripts/manager/apply-cluster.sh",
        "--cluster-id", cluster.id,
        "--name", cluster.name,
        "--controlplane-count", String(cluster.controlplane_count),
        "--worker-count", String(cluster.worker_count),
        "--cpu-cores", String(cluster.cpu_cores),
        "--memory-mb", String(cluster.memory_mb),
        "--disk-gb", String(cluster.disk_gb),
        "--bridge", cluster.bridge,
        "--start-vmid", String(cluster.start_vmid),
        "--start-ip", cluster.start_ip,
        "--vip-ip", cluster.vip_ip,
        "--node-prefix-length", String(cluster.node_prefix_length),
        "--gateway-ip", cluster.gateway_ip,
        "--dns-servers", dnsServers,
        "--dns-domain", cluster.dns_domain,
        "--proxmox-node", cluster.metadata.proxmox_node,
        "--storage-pool", cluster.metadata.storage_pool,
        "--file-datastore", cluster.metadata.file_datastore,
        "--data-dir", dataRoot,
      ],
      secretRuntime.env,
      redact,
      secretRuntime.strip_env,
    );
  } finally {
    secretRuntime.cleanup();
  }
}

async function handleBootstrap(job) {
  const cluster = job.payload.cluster || job.payload;
  await handleApply({ id: job.id, payload: cluster });
}

async function handleRunStep(job) {
  const payload = job.payload;
  const stepId = payload.step_id;
  const stepType = payload.step_type;
  const runner = payload.runner || {};
  const inputs = payload.inputs || {};
  const context = payload.context || {};
  const scriptPath = runner.script;

  if (!stepId) {
    throw new Error("run_step payload missing step_id");
  }
  if (!stepType) {
    throw new Error("run_step payload missing step_type");
  }
  if (!scriptPath) {
    throw new Error("run_step payload missing runner.script");
  }

  const clusterId = context?.cluster?.id || job.cluster_id || null;
  const resultFile = path.join(dirs.stepResults, `${job.id}.json`);
  fs.rmSync(resultFile, { force: true });

  updateStepState(stepId, {
    status: "running",
    inputs,
    outputs: null,
    error: null,
    last_job_id: job.id,
    cluster_id: clusterId,
    started_at: now(),
    finished_at: null,
  });

  const secretRuntime = resolveJobSecretRuntime(payload, clusterId);
  const redact = buildRedactor(secretRuntime.redactions);

  try {
    await runCommand(
      job.id,
      "bash",
      [scriptPath],
      {
        STEP_ID: stepId,
        STEP_TYPE: stepType,
        STEP_INPUTS_JSON: JSON.stringify(inputs),
        STEP_CONTEXT_JSON: JSON.stringify(context),
        STEP_RESULT_FILE: resultFile,
        TWINBOX_HOST_CRON_DIR: process.env.TWINBOX_HOST_CRON_DIR || "/host/etc/cron.d",
        ...secretRuntime.env,
      },
      redact,
      secretRuntime.strip_env,
    );

    const outputs = readJsonIfExists(resultFile);
    updateStepState(stepId, {
      status: stepType === "config" ? "configured" : "succeeded",
      outputs,
      error: null,
      last_job_id: job.id,
      cluster_id: outputs?.cluster_id || clusterId,
      finished_at: now(),
    });
  } catch (err) {
    updateStepState(stepId, {
      status: "failed",
      error: err.message,
      last_job_id: job.id,
      cluster_id: clusterId,
      finished_at: now(),
    });
    throw err;
  } finally {
    secretRuntime.cleanup();
    fs.rmSync(resultFile, { force: true });
  }
}

async function handleJob(queueFile) {
  const queued = readJson(queueFile);
  const runningFile = path.join(dirs.running, path.basename(queueFile));
  fs.renameSync(queueFile, runningFile);

  updateJob(queued.id, { status: "running", step: "started", started_at: now() });
  appendLog(queued.id, `running job type=${queued.type}`);

  try {
    if (queued.type === "apply_cluster") {
      await handleApply({ id: queued.id, payload: queued.payload });
    } else if (queued.type === "create_cluster") {
      await handleApply({ id: queued.id, payload: queued.payload });
    } else if (queued.type === "bootstrap_cluster") {
      await handleBootstrap({ id: queued.id, payload: queued.payload });
    } else if (queued.type === "run_step") {
      await handleRunStep({ id: queued.id, payload: queued.payload, cluster_id: queued.cluster_id });
    } else {
      throw new Error(`unsupported job type: ${queued.type}`);
    }

    updateJob(queued.id, { status: "succeeded", step: "completed", finished_at: now() });
    appendLog(queued.id, "job completed");
  } catch (err) {
    updateJob(queued.id, { status: "failed", step: "failed", error: err.message, finished_at: now() });
    appendLog(queued.id, `job failed: ${err.message}`);
  } finally {
    fs.renameSync(runningFile, path.join(dirs.completed, path.basename(runningFile)));
  }
}

function pickNextJob() {
  const entries = fs.readdirSync(dirs.pending).filter((f) => f.endsWith(".json"));
  if (entries.length === 0) {
    return null;
  }
  entries.sort();
  return path.join(dirs.pending, entries[0]);
}

async function loop() {
  const next = pickNextJob();
  if (next) {
    await handleJob(next);
  }
  setTimeout(loop, pollMs);
}

console.log("manager-worker started");
try {
  ensureToolVersionsMatchPolicy();
  console.log("manager-worker tool version check passed");
} catch (err) {
  console.error(`manager-worker startup failed: ${err.message}`);
  process.exit(1);
}
loop();
