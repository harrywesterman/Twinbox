import fs from "fs";
import path from "path";
import { spawn, spawnSync } from "child_process";
import { buildRedactor } from "../../lib/secrets/redact.mjs";
import {
  buildClusterWorkerSecretBundle,
  normalizeSecretBundle,
} from "../../lib/secrets/schema.mjs";
import {
  readItemRecord,
  resolveAttachmentPath,
} from "../../lib/secrets/filesystem-store.mjs";

const dataRoot = process.env.MANAGER_DATA_DIR || "/data";
const workspace = process.env.WORKSPACE_ROOT || "/opt/twinbox";
const pollMs = Number(process.env.WORKER_POLL_MS || 2000);

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

function now() {
  return new Date().toISOString();
}

function clusterScopeId(cluster = null, fallback = null) {
  return cluster?.cluster_instance_id || cluster?.instance_id || fallback || null;
}

function stepStatePath(stepId, clusterScope = null) {
  const scope = clusterScope ? path.join("clusters", clusterScope) : "global";
  return path.join(dirs.stepState, scope, `${stepId}.json`);
}

function readStepState(stepId, clusterScope = null) {
  return readJsonIfExists(stepStatePath(stepId, clusterScope));
}

function updateStepState(stepId, patch, clusterScope = null) {
  const file = stepStatePath(stepId, clusterScope);
  const current = readStepState(stepId, clusterScope) || {
    step_id: stepId,
    status: "not_started",
    inputs: {},
    outputs: null,
    cluster_id: clusterScope || null,
    cluster_instance_id: patch.cluster_instance_id ?? clusterScope ?? null,
    error: null,
    last_job_id: null,
    created_at: now(),
  };
  const next = {
    ...current,
    ...patch,
    step_id: stepId,
    cluster_id: patch.cluster_id ?? current.cluster_id ?? clusterScope ?? null,
    cluster_instance_id: patch.cluster_instance_id ?? current.cluster_instance_id ?? clusterScope ?? null,
    updated_at: now(),
  };
  writeJson(file, next);
  return next;
}

function queueMarkerPath(filePath) {
  return path.join(dirs.completed, path.basename(filePath));
}

function finalizeQueueMarker(filePath) {
  if (!fs.existsSync(filePath)) {
    return;
  }

  const completedFile = queueMarkerPath(filePath);
  fs.rmSync(completedFile, { force: true });
  fs.renameSync(filePath, completedFile);
}

function recoverOrphanedRunningJobs() {
  const entries = fs.readdirSync(dirs.running).filter((f) => f.endsWith(".json"));
  entries.sort();

  for (const entry of entries) {
    const runningFile = path.join(dirs.running, entry);
    let queued = null;
    try {
      queued = readJson(runningFile);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error || "unknown error");
      appendLog(entry.replace(/\.json$/, ""), `job recovery skipped: unable to read running marker: ${message}`);
      finalizeQueueMarker(runningFile);
      continue;
    }

    const jobId = String(queued?.id || "").trim();
    const failureMessage = "worker restarted while job was running";
    if (!jobId) {
      appendLog(entry.replace(/\.json$/, ""), `job recovery skipped: running marker missing job id`);
      finalizeQueueMarker(runningFile);
      continue;
    }

    try {
      updateJob(jobId, {
        status: "failed",
        step: "failed",
        error: failureMessage,
        finished_at: now(),
      });
      appendLog(jobId, `job failed: ${failureMessage}`);

      if (queued.type === "run_step" && queued.payload?.step_id) {
        const clusterId = queued.cluster_id || queued.payload?.cluster_id || queued.payload?.context?.cluster?.id || null;
        const clusterInstanceId = queued.cluster_instance_id || queued.payload?.cluster_instance_id || queued.payload?.context?.cluster?.cluster_instance_id || queued.payload?.context?.cluster?.instance_id || null;
        updateStepState(queued.payload.step_id, {
          status: "failed",
          error: failureMessage,
          last_job_id: jobId,
          cluster_id: clusterId,
          cluster_instance_id: clusterInstanceId,
          finished_at: now(),
        }, clusterInstanceId || clusterId);
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error || "unknown error");
      appendLog(jobId, `job recovery failed: ${message}`);
    } finally {
      finalizeQueueMarker(runningFile);
    }
  }
}

function trimString(value) {
  return typeof value === "string" ? value.trim() : "";
}

function resolveFieldValue(record, ref) {
  if (!record || typeof record !== "object") {
    return "";
  }

  const aliases = {
    proxmox: {
      host: ["host"],
      port: ["port"],
      username: ["username", "user"],
      password: ["password"],
      endpoint: ["endpoint"],
    },
    "wiredoor-gateway": {
      WIREDOOR_URL: ["WIREDOOR_URL", "username", "url"],
      TOKEN: ["TOKEN", "password", "token"],
      username: ["WIREDOOR_URL", "username", "url"],
      password: ["TOKEN", "password", "token"],
    },
    grafana: {
      "admin-user": ["admin-user", "username"],
      "admin-password": ["admin-password", "password"],
    },
    "traefik-dashboard": {
      username: ["username"],
      password: ["password"],
      users: ["users"],
    },
  };

  const fieldAliases = aliases[ref.item]?.[ref.field] || [ref.field];
  for (const key of fieldAliases) {
    const value = record[key];
    if (value !== undefined && value !== null && String(value).trim() !== "") {
      return String(value);
    }
  }
  return "";
}

function envFallbackRecord(ref) {
  if (ref.scope !== "global" || ref.item !== "proxmox") {
    return null;
  }

  const host = trimString(process.env.PROXMOX_HOST);
  const port = trimString(process.env.PROXMOX_PORT);
  const username = trimString(process.env.PROXMOX_USER || process.env.PROXMOX_USERNAME);
  const password = trimString(process.env.PROXMOX_PASSWORD || process.env.TF_VAR_proxmox_password);
  const endpoint = trimString(
    process.env.TF_VAR_proxmox_endpoint
    || (host && port ? `https://${host}:${port}` : ""),
  );

  const record = {};
  if (host) record.host = host;
  if (port) record.port = port;
  if (username) record.username = username;
  if (password) record.password = password;
  if (endpoint) record.endpoint = endpoint;

  return Object.keys(record).length > 0 ? record : null;
}

function readSecretRecord(ref, context = {}) {
  return readItemRecord(process.env, ref, context) || envFallbackRecord(ref);
}

function resolveTextRef(rawRef, context = {}) {
  const ref = rawRef;
  const record = readSecretRecord(ref, context);
  const value = resolveFieldValue(record, ref);

  if (!value) {
    throw new Error(`secret field not found: ${ref.field} on ${ref.scope === "cluster" ? `${ref.cluster_id || context.clusterId || context.cluster_id}/${ref.item}` : ref.item}`);
  }

  return value;
}

function materializeRef(rawRef, label, context = {}) {
  const ref = rawRef;
  if (ref.attachment) {
    const attachmentPath = resolveAttachmentPath(process.env, ref, context);
    if (!fs.existsSync(attachmentPath)) {
      throw new Error(`secret attachment not found: ${attachmentPath}`);
    }
    return attachmentPath;
  }

  const value = resolveTextRef(ref, context);
  const tempRoot = process.env.TWINBOX_SECRET_TEMP_DIR || path.join(process.env.MANAGER_DATA_DIR || "/tmp", "twinbox-secrets");
  fs.mkdirSync(tempRoot, { recursive: true, mode: 0o700 });
  const targetDir = fs.mkdtempSync(path.join(tempRoot, `${String(label || "secret").replace(/[^a-zA-Z0-9_.-]+/g, "-")}-`));
  const targetFile = path.join(targetDir, "value");
  fs.writeFileSync(targetFile, value, { mode: 0o600 });
  return targetFile;
}

function resolveSecretBundle(bundleSpec = {}, context = {}) {
  const bundle = normalizeSecretBundle(bundleSpec);
  const env = {};
  const files = {};
  const redactions = [];
  const cleanupDirs = new Set();

  for (const [name, ref] of Object.entries(bundle.env)) {
    try {
      const fileLike = ref.format === "file" || ref.attachment;
      if (fileLike) {
        const filePath = materializeRef(ref, name, context);
        env[name] = filePath;
        files[name] = filePath;
        if (!ref.attachment) {
          cleanupDirs.add(path.dirname(filePath));
        }
        continue;
      }

      const value = resolveTextRef(ref, context);
      env[name] = value;
      if (name.includes("PASSWORD") || ref.field === "password") {
        redactions.push(value);
      }
    } catch (error) {
      if (ref.optional) {
        continue;
      }
      throw error;
    }
  }

  for (const [name, ref] of Object.entries(bundle.files)) {
    try {
      const filePath = materializeRef(ref, name, context);
      env[name] = filePath;
      files[name] = filePath;
      if (!ref.attachment) {
        cleanupDirs.add(path.dirname(filePath));
      }
    } catch (error) {
      if (ref.optional) {
        continue;
      }
      throw error;
    }
  }

  return {
    env,
    files,
    redactions,
    cleanup() {
      for (const dir of cleanupDirs) {
        fs.rmSync(dir, { recursive: true, force: true });
      }
    },
  };
}

function runCommand(jobId, command, args, env = {}, redactLine = (line) => String(line ?? ""), stripEnv = []) {
  return new Promise((resolve, reject) => {
    appendLog(jobId, `exec: ${command} ${args.join(" ")}`);
    const recentOutput = [];
    let settled = false;
    let cancelRequested = false;
    let cancelTimer = null;
    let killTimer = null;

    const jobFile = path.join(dirs.jobs, `${jobId}.json`);

    const clearTimers = () => {
      if (cancelTimer) {
        clearInterval(cancelTimer);
        cancelTimer = null;
      }
      if (killTimer) {
        clearTimeout(killTimer);
        killTimer = null;
      }
    };

    const finishResolve = () => {
      if (settled) return;
      settled = true;
      clearTimers();
      resolve();
    };

    const finishReject = (error) => {
      if (settled) return;
      settled = true;
      clearTimers();
      reject(error);
    };

    const recordChunk = (chunk) => {
      const text = chunk.toString();
      for (const line of text.split(/\r?\n/)) {
        const trimmed = line.trimEnd();
        if (!trimmed) continue;
        const redacted = redactLine(trimmed);
        recentOutput.push(redacted);
        if (recentOutput.length > 100) {
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
      detached: true,
    });

    const terminateChild = (signal) => {
      if (cancelRequested) {
        return;
      }
      cancelRequested = true;
      appendLog(jobId, "cancel requested; stopping running process");
      try {
        process.kill(-child.pid, signal);
      } catch {
        child.kill(signal);
      }
      killTimer = setTimeout(() => {
        try {
          process.kill(-child.pid, "SIGKILL");
        } catch {
          child.kill("SIGKILL");
        }
      }, 10000);
    };

    cancelTimer = setInterval(() => {
      const job = readJsonIfExists(jobFile);
      if (job?.status === "cancel_requested" || job?.status === "canceled") {
        terminateChild("SIGTERM");
      }
    }, 500);

    child.stdout.on("data", recordChunk);
    child.stderr.on("data", recordChunk);

    child.on("error", (err) => finishReject(err));
    child.on("close", (code) => {
      if (cancelRequested) {
        finishReject(new Error("job canceled"));
        return;
      }

      if (code === 0) {
        finishResolve();
      } else {
        finishReject(new Error(summarizeFailureOutput(recentOutput, `command exited with code ${code}`)));
      }
    });
  });
}

function isJobCanceled(jobId) {
  const job = readJsonIfExists(path.join(dirs.jobs, `${jobId}.json`));
  return job?.status === "cancel_requested" || job?.status === "canceled";
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

  const runtime = resolveSecretBundle(secretBundle, {
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
  if (!values.PINNED_KUBECTL_VERSION) {
    throw new Error(`missing PINNED_KUBECTL_VERSION in ${file}`);
  }
  if (!values.PINNED_HELM_VERSION) {
    throw new Error(`missing PINNED_HELM_VERSION in ${file}`);
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
  const expectedKubectl = normalizeVersion(pinnedDefaults.PINNED_KUBECTL_VERSION);
  const expectedHelm = normalizeVersion(pinnedDefaults.PINNED_HELM_VERSION);

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
  const clusterInstanceId = clusterScopeId(context?.cluster, job.cluster_instance_id || null);
  const resultFile = path.join(dirs.stepResults, `${job.id}.json`);
  fs.rmSync(resultFile, { force: true });

  updateStepState(stepId, {
    status: "running",
    inputs,
    outputs: null,
    error: null,
    last_job_id: job.id,
    cluster_id: clusterId,
    cluster_instance_id: clusterInstanceId,
    started_at: now(),
    finished_at: null,
  }, clusterInstanceId || clusterId);

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
        TWINBOX_CLUSTER_ID: clusterId || "",
        TWINBOX_CLUSTER_INSTANCE_ID: clusterInstanceId || "",
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
      cluster_instance_id: outputs?.cluster_instance_id || clusterInstanceId,
      finished_at: now(),
    }, clusterInstanceId || clusterId);
  } catch (err) {
    if (String(err?.message || "") === "job canceled") {
      updateStepState(stepId, {
        status: "canceled",
        error: null,
        last_job_id: job.id,
        cluster_id: clusterId,
        cluster_instance_id: clusterInstanceId,
        finished_at: now(),
      }, clusterInstanceId || clusterId);
      throw err;
    }
    updateStepState(stepId, {
      status: "failed",
      error: err.message,
      last_job_id: job.id,
      cluster_id: clusterId,
      cluster_instance_id: clusterInstanceId,
      finished_at: now(),
    }, clusterInstanceId || clusterId);
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
      await handleRunStep({
        id: queued.id,
        payload: queued.payload,
        cluster_id: queued.cluster_id,
        cluster_instance_id: queued.cluster_instance_id,
      });
    } else {
      throw new Error(`unsupported job type: ${queued.type}`);
    }

    if (isJobCanceled(queued.id)) {
      updateJob(queued.id, { status: "canceled", step: "canceled", error: null, finished_at: now() });
      appendLog(queued.id, "job canceled");
      return;
    }

    updateJob(queued.id, { status: "succeeded", step: "completed", finished_at: now() });
    appendLog(queued.id, "job completed");
  } catch (err) {
    if (String(err?.message || "") === "job canceled") {
      updateJob(queued.id, { status: "canceled", step: "canceled", error: null, finished_at: now() });
      appendLog(queued.id, "job canceled");
    } else {
      updateJob(queued.id, { status: "failed", step: "failed", error: err.message, finished_at: now() });
      appendLog(queued.id, `job failed: ${err.message}`);
    }
  } finally {
    finalizeQueueMarker(runningFile);
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
  recoverOrphanedRunningJobs();
  console.log("manager-worker recovered orphaned running jobs");
} catch (err) {
  console.error(`manager-worker startup recovery failed: ${err.message}`);
  process.exit(1);
}
try {
  ensureToolVersionsMatchPolicy();
  console.log("manager-worker tool version check passed");
} catch (err) {
  console.error(`manager-worker startup failed: ${err.message}`);
  process.exit(1);
}
loop();
