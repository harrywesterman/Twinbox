import fs from "fs";
import path from "path";
import { spawn } from "child_process";

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
};

Object.values(dirs).forEach((dir) => fs.mkdirSync(dir, { recursive: true }));

function now() {
  return new Date().toISOString();
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function writeJson(file, value) {
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

function runCommand(jobId, command, args, env = {}) {
  return new Promise((resolve, reject) => {
    appendLog(jobId, `exec: ${command} ${args.join(" ")}`);
    const child = spawn(command, args, {
      cwd: workspace,
      env: { ...process.env, ...env },
      stdio: ["ignore", "pipe", "pipe"],
    });

    child.stdout.on("data", (chunk) => appendLog(jobId, chunk.toString().trimEnd()));
    child.stderr.on("data", (chunk) => appendLog(jobId, chunk.toString().trimEnd()));

    child.on("error", (err) => reject(err));
    child.on("close", (code) => {
      if (code === 0) {
        resolve();
      } else {
        reject(new Error(`command exited with code ${code}`));
      }
    });
  });
}

async function handleCreate(job) {
  const cluster = job.payload;
  await runCommand(
    job.id,
    "bash",
    [
      "scripts/manager/create-talos-vms.sh",
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
      "--proxmox-node", cluster.metadata.proxmox_node,
      "--storage-pool", cluster.metadata.storage_pool,
      "--iso-storage", cluster.metadata.iso_storage,
      "--talos-iso-file", cluster.metadata.talos_iso_file,
      "--data-dir", dataRoot,
    ],
  );
}

async function handleBootstrap(job) {
  const payload = job.payload;
  const cluster = payload.cluster;
  const controlplaneIps = (payload.controlplane_ips || []).join(",");
  const workerIps = (payload.worker_ips || []).join(",");

  await runCommand(
    job.id,
    "bash",
    [
      "scripts/manager/bootstrap-talos.sh",
      "--cluster-id", cluster.id,
      "--name", cluster.name,
      "--vip-ip", payload.vip_ip,
      "--controlplane-ips", controlplaneIps,
      "--worker-ips", workerIps,
      "--data-dir", dataRoot,
    ],
  );
}

async function handleJob(queueFile) {
  const queued = readJson(queueFile);
  const runningFile = path.join(dirs.running, path.basename(queueFile));
  fs.renameSync(queueFile, runningFile);

  updateJob(queued.id, { status: "running", step: "started", started_at: now() });
  appendLog(queued.id, `running job type=${queued.type}`);

  try {
    if (queued.type === "create_cluster") {
      await handleCreate({ id: queued.id, payload: queued.payload });
    } else if (queued.type === "bootstrap_cluster") {
      await handleBootstrap({ id: queued.id, payload: queued.payload });
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
loop();
