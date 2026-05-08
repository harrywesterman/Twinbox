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

const OBSERVABILITY_PROFILES = new Set(["full", "minimal", "off"]);

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

function parseQueuedAt(queuedAt) {
  if (typeof queuedAt !== "string") {
    return null;
  }

  const parsed = Date.parse(queuedAt);
  return Number.isFinite(parsed) ? parsed : null;
}

function clusterScopeId(cluster = null, fallback = null) {
  return cluster?.cluster_instance_id || cluster?.instance_id || fallback || null;
}

function readKnownClusters() {
  if (!fs.existsSync(dirs.clusters)) {
    return [];
  }

  return fs.readdirSync(dirs.clusters)
    .filter((entry) => entry.endsWith(".json"))
    .map((entry) => readJsonIfExists(path.join(dirs.clusters, entry)))
    .filter((cluster) => cluster?.id)
    .sort((left, right) => String(right?.updated_at || right?.created_at || "").localeCompare(String(left?.updated_at || left?.created_at || "")));
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

function updateClusterState(clusterId, patch) {
  if (!clusterId) {
    return null;
  }

  const file = path.join(dirs.clusters, `${clusterId}.json`);
  if (!fs.existsSync(file)) {
    return null;
  }

  const current = readJson(file);
  const next = {
    ...current,
    ...patch,
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

function readPendingJobCandidate(file) {
  const fullPath = path.join(dirs.pending, file);

  try {
    const stat = fs.statSync(fullPath);
    let queuedAtMs = null;

    try {
      const queued = readJson(fullPath);
      queuedAtMs = parseQueuedAt(queued?.queued_at);
    } catch {
      queuedAtMs = null;
    }

    const mtimeMs = Number.isFinite(stat.mtimeMs) ? stat.mtimeMs : Number.MAX_SAFE_INTEGER;
    return {
      file,
      fullPath,
      queuedAtMs: queuedAtMs ?? mtimeMs,
      mtimeMs,
    };
  } catch {
    return null;
  }
}

function comparePendingJobs(left, right) {
  if (left.queuedAtMs !== right.queuedAtMs) {
    return left.queuedAtMs - right.queuedAtMs;
  }

  if (left.mtimeMs !== right.mtimeMs) {
    return left.mtimeMs - right.mtimeMs;
  }

  return left.file.localeCompare(right.file);
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
      const currentJob = readJson(path.join(dirs.jobs, `${jobId}.json`));
      const wasCancelRequested = currentJob?.status === "cancel_requested" || currentJob?.status === "canceled";

      updateJob(jobId, {
        status: wasCancelRequested ? "canceled" : "failed",
        step: wasCancelRequested ? "canceled" : "failed",
        error: wasCancelRequested ? null : failureMessage,
        finished_at: now(),
      });
      appendLog(jobId, wasCancelRequested ? "job canceled" : `job failed: ${failureMessage}`);

      if ((queued.type === "run_step" || queued.type === "uninstall_step") && queued.payload?.step_id) {
        const clusterId = queued.cluster_id || queued.payload?.cluster_id || queued.payload?.context?.cluster?.id || null;
        const clusterInstanceId = queued.cluster_instance_id || queued.payload?.cluster_instance_id || queued.payload?.context?.cluster?.cluster_instance_id || queued.payload?.context?.cluster?.instance_id || null;
        updateStepState(queued.payload.step_id, {
          status: wasCancelRequested ? "canceled" : "failed",
          error: wasCancelRequested ? null : failureMessage,
          last_job_id: jobId,
          cluster_id: clusterId,
          cluster_instance_id: clusterInstanceId,
          finished_at: now(),
        }, clusterInstanceId || clusterId);
      }

      if (queued.type === "reconcile_observability") {
        const clusterId = queued.cluster_id || queued.payload?.cluster?.id || null;
        const cluster = queued.payload?.cluster || {};
        const desiredProfile = OBSERVABILITY_PROFILES.has(String(queued.payload?.desired_profile || cluster.observability_profile || "full").trim().toLowerCase())
          ? String(queued.payload?.desired_profile || cluster.observability_profile || "full").trim().toLowerCase()
          : "full";
        updateClusterState(clusterId, {
          ...cluster,
          observability_profile: desiredProfile,
          observability_status: "failed",
          observability_error: failureMessage,
          observability_last_job_id: jobId,
          observability_updated_at: now(),
        });
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

    const getProcessGroupId = (pid) => {
      try {
        const stat = fs.readFileSync(`/proc/${pid}/stat`, "utf8");
        const fields = stat.trim().split(/\s+/);
        return Number.parseInt(fields[4], 10);
      } catch {
        return null;
      }
    };

    const killProcessGroup = (signal) => {
      const targets = new Set([child.pid]);
      const pgid = getProcessGroupId(child.pid);
      if (Number.isFinite(pgid) && pgid > 1) {
        targets.add(-pgid);
      }

      for (const target of targets) {
        try {
          process.kill(target, signal);
        } catch {
          // Best effort only; try the next target.
        }
      }
    };

    const terminateChild = (signal) => {
      if (cancelRequested) {
        return;
      }
      cancelRequested = true;
      appendLog(jobId, "cancel requested; stopping running process");
      killProcessGroup(signal);
      killTimer = setTimeout(() => {
        killProcessGroup("SIGKILL");
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

function withKubeconfigAliases(env = {}) {
  const next = { ...env };
  const kubeconfig = next.KUBECONFIG_FILE || next.TWINBOX_KUBECONFIG_FILE || next.KUBECONFIG;

  if (kubeconfig && !next.KUBECONFIG_FILE) {
    next.KUBECONFIG_FILE = kubeconfig;
  }
  if (kubeconfig && !next.KUBECONFIG) {
    next.KUBECONFIG = kubeconfig;
  }

  return next;
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

async function handleReconcileObservability(job) {
  const payload = job.payload || {};
  const cluster = payload.cluster || {};
  const clusterId = cluster?.id || job.cluster_id || null;
  const clusterInstanceId = clusterScopeId(cluster, job.cluster_instance_id || null);
  const desiredProfile = OBSERVABILITY_PROFILES.has(String(payload.desired_profile || cluster.observability_profile || "full").trim().toLowerCase())
    ? String(payload.desired_profile || cluster.observability_profile || "full").trim().toLowerCase()
    : "full";
  const secretRuntime = resolveJobSecretRuntime(payload, clusterId);
  const redact = buildRedactor(secretRuntime.redactions);
  const reconcileCluster = {
    ...cluster,
    observability_profile: desiredProfile,
    observability_status: "applying",
    observability_error: null,
    observability_last_job_id: job.id,
    observability_updated_at: now(),
  };

  updateClusterState(clusterId, {
    ...reconcileCluster,
    observability_status: "applying",
    observability_error: null,
    observability_last_job_id: job.id,
    observability_updated_at: now(),
  });

  try {
    const scriptEnv = withKubeconfigAliases({
      STEP_CONTEXT_JSON: JSON.stringify({ cluster: reconcileCluster }),
      OBSERVABILITY_PROFILE: desiredProfile,
      TWINBOX_OBSERVABILITY_PROFILE: desiredProfile,
      TWINBOX_CLUSTER_ID: clusterId || "",
      TWINBOX_CLUSTER_INSTANCE_ID: clusterInstanceId || "",
      ...secretRuntime.env,
    });

    await runCommand(
      job.id,
      "bash",
      ["scripts/manager/reconcile-observability.sh"],
      scriptEnv,
      redact,
      secretRuntime.strip_env,
    );

    updateClusterState(clusterId, {
      ...reconcileCluster,
      observability_status: "ready",
      observability_error: null,
      observability_last_job_id: job.id,
      observability_updated_at: now(),
    });
  } catch (err) {
    updateClusterState(clusterId, {
      ...reconcileCluster,
      observability_status: "failed",
      observability_error: err.message,
      observability_last_job_id: job.id,
      observability_updated_at: now(),
    });
    throw err;
  } finally {
    secretRuntime.cleanup();
  }
}

async function handleBootstrap(job) {
  const cluster = job.payload.cluster || job.payload;
  await handleApply({ id: job.id, payload: cluster });
}

async function refreshDashyConfig(jobId, stepId, clusterId, clusterInstanceId, env, redact, stripEnv) {
  if (!clusterId) {
    return;
  }

  try {
    await runCommand(
      jobId,
      "node",
      [
        "manager-worker/src/refresh-dashy-config.mjs",
        "--workspace-root", workspace,
        "--manager-data-dir", dataRoot,
        "--cluster-id", clusterId,
        "--trigger-step-id", stepId,
        ...(clusterInstanceId ? ["--cluster-instance-id", clusterInstanceId] : []),
      ],
      env,
      redact,
      stripEnv,
    );
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error || "unknown error");
    appendLog(jobId, `dashy refresh warning: ${message}`);
  }
}

async function refreshPortalConfig(jobId, stepId, clusterId, clusterInstanceId, env, redact, stripEnv) {
  if (!clusterId) {
    return;
  }

  try {
    await runCommand(
      jobId,
      "node",
      [
        "manager-worker/src/refresh-portal-config.mjs",
        "--workspace-root", workspace,
        "--manager-data-dir", dataRoot,
        "--cluster-id", clusterId,
        "--trigger-step-id", stepId,
        ...(clusterInstanceId ? ["--cluster-instance-id", clusterInstanceId] : []),
      ],
      env,
      redact,
      stripEnv,
    );
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error || "unknown error");
    appendLog(jobId, `portal refresh warning: ${message}`);
  }
}

async function refreshGrafanaDashboard(jobId, stepId, clusterId, clusterInstanceId, env, redact, stripEnv) {
  if (!clusterId) {
    return;
  }

  try {
    await runCommand(
      jobId,
      "node",
      [
        "scripts/manager/refresh-grafana-dashboard.mjs",
        "--manager-data-dir",
        dataRoot,
        "--cluster-id",
        clusterId,
        "--trigger-step-id",
        stepId,
        ...(clusterInstanceId ? ["--cluster-instance-id", clusterInstanceId] : []),
        "--namespace",
        "monitoring",
      ],
      env,
      redact,
      stripEnv,
    );
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error || "unknown error");
    appendLog(jobId, `grafana refresh warning: ${message}`);
  }
}

async function reconcileGrafanaDashboardsOnStartup() {
  const clusters = readKnownClusters();

  for (const cluster of clusters) {
    if (!cluster?.id || !cluster?.metadata) {
      continue;
    }

    let secretRuntime;
    try {
      secretRuntime = resolveJobSecretRuntime(cluster, cluster.id);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error || "unknown error");
      console.warn(`manager-worker startup grafana reconcile skipped for ${cluster.id}: ${message}`);
      continue;
    }

    const hasKubeconfig = Boolean(
      secretRuntime.env.KUBECONFIG_FILE
      || secretRuntime.env.TWINBOX_KUBECONFIG_FILE
      || secretRuntime.env.KUBECONFIG,
    );

    if (!hasKubeconfig) {
      secretRuntime.cleanup();
      continue;
    }

    try {
      await refreshGrafanaDashboard(
        `startup-grafana-${cluster.id}`,
        "manager-worker-startup",
        cluster.id,
        clusterScopeId(cluster, cluster.id),
        secretRuntime.env,
        buildRedactor(secretRuntime.redactions),
        secretRuntime.strip_env,
      );
    } finally {
      secretRuntime.cleanup();
    }
  }
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

    await refreshDashyConfig(
      job.id,
      stepId,
      outputs?.cluster_id || clusterId,
      outputs?.cluster_instance_id || clusterInstanceId,
      secretRuntime.env,
      redact,
      secretRuntime.strip_env,
    );
    await refreshPortalConfig(
      job.id,
      stepId,
      outputs?.cluster_id || clusterId,
      outputs?.cluster_instance_id || clusterInstanceId,
      secretRuntime.env,
      redact,
      secretRuntime.strip_env,
    );
    await refreshGrafanaDashboard(
      job.id,
      stepId,
      outputs?.cluster_id || clusterId,
      outputs?.cluster_instance_id || clusterInstanceId,
      secretRuntime.env,
      redact,
      secretRuntime.strip_env,
    );
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

async function handleUninstallStep(job) {
  const payload = job.payload;
  const stepId = payload.step_id;
  const stepType = payload.step_type;
  const appName = payload.app_name;
  const manifestPath = payload.manifest_path;
  const applicationSetName = payload.application_set_name || "";
  const context = payload.context || {};

  if (!stepId) {
    throw new Error("uninstall_step payload missing step_id");
  }
  if (!stepType) {
    throw new Error("uninstall_step payload missing step_type");
  }
  if (!appName) {
    throw new Error("uninstall_step payload missing app_name");
  }
  if (!manifestPath) {
    throw new Error("uninstall_step payload missing manifest_path");
  }

  const clusterId = context?.cluster?.id || job.cluster_id || null;
  const clusterInstanceId = clusterScopeId(context?.cluster, job.cluster_instance_id || null);
  const secretRuntime = resolveJobSecretRuntime(payload, clusterId);
  const redact = buildRedactor(secretRuntime.redactions);
  updateStepState(stepId, {
    status: "running",
    inputs: {},
    outputs: null,
    error: null,
    last_job_id: job.id,
    cluster_id: clusterId,
    cluster_instance_id: clusterInstanceId,
    started_at: now(),
    finished_at: null,
  }, clusterInstanceId || clusterId);

  try {
    await runCommand(
      job.id,
      "bash",
      ["scripts/manager/uninstall-argocd-application.sh"],
      {
        APP_NAME: appName,
        APPLICATION_SET_NAME: applicationSetName,
        MANIFEST_PATH: manifestPath,
        STEP_ID: stepId,
        STEP_TYPE: stepType,
        TWINBOX_CLUSTER_ID: clusterId || "",
        TWINBOX_CLUSTER_INSTANCE_ID: clusterInstanceId || "",
        ...secretRuntime.env,
      },
      redact,
      secretRuntime.strip_env,
    );

    updateStepState(stepId, {
      status: "not_started",
      inputs: {},
      outputs: null,
      error: null,
      last_job_id: job.id,
      cluster_id: clusterId,
      cluster_instance_id: clusterInstanceId,
      finished_at: now(),
    }, clusterInstanceId || clusterId);

    await refreshPortalConfig(
      job.id,
      stepId,
      clusterId,
      clusterInstanceId,
      secretRuntime.env,
      redact,
      secretRuntime.strip_env,
    );
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
    } else if (queued.type === "reconcile_observability") {
      await handleReconcileObservability({
        id: queued.id,
        payload: queued.payload,
        cluster_id: queued.cluster_id,
        cluster_instance_id: queued.cluster_instance_id,
      });
    } else if (queued.type === "run_step") {
      await handleRunStep({
        id: queued.id,
        payload: queued.payload,
        cluster_id: queued.cluster_id,
        cluster_instance_id: queued.cluster_instance_id,
      });
    } else if (queued.type === "uninstall_step") {
      await handleUninstallStep({
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

  const nextJobs = entries
    .map(readPendingJobCandidate)
    .filter(Boolean)
    .sort(comparePendingJobs);

  return nextJobs[0]?.fullPath || null;
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
reconcileGrafanaDashboardsOnStartup()
  .then(() => {
    console.log("manager-worker startup grafana reconcile complete");
    loop();
  })
  .catch((err) => {
    console.error(`manager-worker startup grafana reconcile failed: ${err.message}`);
    process.exit(1);
  });
