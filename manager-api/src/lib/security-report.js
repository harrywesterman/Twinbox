import fs from "node:fs/promises";
import path from "node:path";
import { unzipSync } from "fflate";

const API = "https://api.github.com/repos/harrywesterman/Twinbox";
const WORKFLOW = "image-vulnerability-monitor.yml";
const REPORT_NAME = "twinbox-security-report";
const REPORT_FILE = "security-report.json";
const MAX_BYTES = 10 * 1024 * 1024;
const TTL_MS = 15 * 60_000;
const IMAGE_KEYS = new Set([
  "manager_api",
  "manager_worker",
  "manager_web",
  "portal",
  "twinbox_agents",
  "jitsi_openid",
  "twinbox_dev_workspace",
]);

async function githubJson(url, token) {
  const response = await fetch(url, {
    signal: AbortSignal.timeout(10_000),
    headers: {
      Accept: "application/vnd.github+json",
      Authorization: `Bearer ${token}`,
      "User-Agent": "Twinbox-security-overview",
    },
    redirect: "error",
  });
  if (!response.ok) throw new Error(`GitHub API returned ${response.status}`);
  return response.json();
}

async function downloadArtifact(url, token) {
  const first = await fetch(url, {
    signal: AbortSignal.timeout(10_000),
    headers: { Authorization: `Bearer ${token}`, Accept: "application/vnd.github+json" },
    redirect: "manual",
  });
  if (first.status !== 302) throw new Error(`Artifact download returned ${first.status}`);
  const location = new URL(first.headers.get("location") || "");
  if (location.protocol !== "https:" || !location.hostname)
    throw new Error("Unsafe artifact redirect");
  const second = await fetch(location, { signal: AbortSignal.timeout(10_000), redirect: "error" });
  if (!second.ok) throw new Error(`Artifact storage returned ${second.status}`);
  const bytes = new Uint8Array(await second.arrayBuffer());
  if (bytes.length > MAX_BYTES) throw new Error("Artifact exceeds 10 MiB");
  const extracted = unzipSync(bytes, {
    filter: (file) => file.name === REPORT_FILE && file.originalSize <= MAX_BYTES,
  });
  const body = extracted[REPORT_FILE];
  if (!body || body.length > MAX_BYTES) throw new Error("Missing or oversized report");
  return JSON.parse(new TextDecoder().decode(body));
}

export function validateSecurityReport(report, run) {
  if (
    report?.schemaVersion !== 1 ||
    report.repository !== "harrywesterman/Twinbox" ||
    String(report.workflowRunId) !== String(run.id) ||
    report.commitSha !== run.head_sha ||
    !Array.isArray(report.images) ||
    report.images.length !== IMAGE_KEYS.size ||
    !report.generatedAt ||
    Number.isNaN(Date.parse(report.generatedAt)) ||
    Date.parse(report.generatedAt) > Date.now() + 5 * 60_000 ||
    report.sourceErrors?.length
  ) {
    throw new Error("Invalid security report metadata");
  }
  const keys = new Set();
  for (const image of report.images) {
    if (
      !IMAGE_KEYS.has(image.key) ||
      keys.has(image.key) ||
      image.scanStatus !== "complete" ||
      !Array.isArray(image.findings) ||
      !/^ghcr\.io\/[^@]+@sha256:[a-f0-9]{64}$/.test(image.digest) ||
      !image.platform?.startsWith("linux/") ||
      !image.scannedAt
    ) {
      throw new Error("Invalid image in security report");
    }
    keys.add(image.key);
  }
  return report;
}

async function fetchLatestReport(token) {
  const runs = await githubJson(
    `${API}/actions/workflows/${WORKFLOW}/runs?branch=main&per_page=20`,
    token
  );
  const applicable = (runs.workflow_runs || []).filter(
    (run) =>
      run.head_branch === "main" &&
      run.repository?.full_name === "harrywesterman/Twinbox" &&
      ["schedule", "workflow_dispatch"].includes(run.event)
  );
  if (!applicable.length) throw new Error("No security scan runs found");
  const newest = applicable[0];
  const complete = applicable.find(
    (run) => run.status === "completed" && run.conclusion === "success"
  );
  if (!complete) throw new Error("No successful complete security scan found");
  const artifacts = await githubJson(
    `${API}/actions/runs/${complete.id}/artifacts?per_page=100`,
    token
  );
  const reportArtifact = (artifacts.artifacts || []).find(
    (item) => item.name === REPORT_NAME && !item.expired
  );
  if (!reportArtifact) throw new Error("Security report artifact missing or expired");
  const report = validateSecurityReport(
    await downloadArtifact(reportArtifact.archive_download_url, token),
    complete
  );
  return {
    report,
    latestRun: { id: newest.id, status: newest.status, conclusion: newest.conclusion },
  };
}

export function createSecurityReportLoader(
  dataRoot,
  token = process.env.TWINBOX_SECURITY_GITHUB_TOKEN
) {
  const snapshotPath = path.join(dataRoot, "security", "latest.json");
  let loadedAt = 0;
  let cached = null;
  let pending = null;

  async function readCache() {
    if (cached) return cached;
    try {
      const previous = JSON.parse(await fs.readFile(snapshotPath, "utf8"));
      validateSecurityReport(previous.report, {
        id: previous.report.workflowRunId,
        head_sha: previous.report.commitSha,
      });
      cached = previous;
    } catch {
      /* no prior snapshot */
    }
    return cached;
  }

  return async function load() {
    await readCache();
    if (!token)
      return {
        report: cached?.report || null,
        error: "Security report access is not configured",
        latestRun: null,
      };
    if (Date.now() - loadedAt < TTL_MS && cached) return { ...cached, error: null };
    if (!pending) {
      pending = (async () => {
        const next = await fetchLatestReport(token);
        await fs.mkdir(path.dirname(snapshotPath), { recursive: true });
        const temp = `${snapshotPath}.${process.pid}.tmp`;
        await fs.writeFile(temp, JSON.stringify(next));
        await fs.rename(temp, snapshotPath);
        cached = next;
        loadedAt = Date.now();
        return next;
      })().finally(() => {
        pending = null;
      });
    }
    try {
      return { ...(await pending), error: null };
    } catch (error) {
      return {
        report: cached?.report || null,
        latestRun: cached?.latestRun || null,
        error: error.message,
      };
    }
  };
}
