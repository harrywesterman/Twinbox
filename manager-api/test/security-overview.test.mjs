import assert from "node:assert/strict";
import test from "node:test";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { zipSync } from "fflate";
import { buildSecurityOverview } from "../src/lib/security-overview.js";
import { createSecurityReportLoader, validateSecurityReport } from "../src/lib/security-report.js";

const now = new Date().toISOString();
const sha = "a".repeat(40);
const digest = `ghcr.io/example/image@sha256:${"b".repeat(64)}`;
const keys = [
  "manager_api",
  "manager_worker",
  "manager_web",
  "portal",
  "twinbox_agents",
  "jitsi_openid",
  "twinbox_dev_workspace",
];

function report() {
  return {
    schemaVersion: 1,
    repository: "harrywesterman/Twinbox",
    workflowRunId: "42",
    commitSha: sha,
    generatedAt: now,
    sourceErrors: [],
    images: keys.map((key) => ({
      key,
      logicalName: key,
      digest,
      platform: "linux/amd64",
      scanStatus: "complete",
      scannedAt: now,
      findings: [],
    })),
  };
}

test("published scans do not imply runtime or other controls were measured", () => {
  const valid = validateSecurityReport(report(), { id: 42, head_sha: sha });
  const overview = buildSecurityOverview(valid);
  assert.equal(overview.published.status, "no_open_findings_in_scope");
  assert.equal(overview.runtime.status, "not_measured");
  assert.ok(overview.topics.every((topic) => topic.status === "not_measured"));
  assert.equal(buildSecurityOverview(valid, "newest run failed").status, "insufficient_data");
});

test("incomplete, stale and wrong-identity reports are not green", () => {
  const incomplete = report();
  incomplete.images.pop();
  assert.throws(() => validateSecurityReport(incomplete, { id: 42, head_sha: sha }));
  const wrongRun = report();
  assert.throws(() => validateSecurityReport(wrongRun, { id: 43, head_sha: sha }));
  const stale = report();
  stale.generatedAt = "2020-01-01T00:00:00Z";
  assert.equal(buildSecurityOverview(stale).status, "insufficient_data");
});

test("loader accepts only the successful main-run artifact and strips token on storage redirect", async () => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "twinbox-security-"));
  const originalFetch = global.fetch;
  const seen = [];
  const goodReport = report();
  const archive = zipSync({
    "security-report.json": new TextEncoder().encode(JSON.stringify(goodReport)),
  });
  const run = {
    id: 42,
    head_sha: sha,
    status: "completed",
    conclusion: "success",
    event: "schedule",
    head_branch: "main",
    repository: { full_name: "harrywesterman/Twinbox" },
  };
  global.fetch = async (url, options = {}) => {
    seen.push({ url: String(url), authorization: options.headers?.Authorization });
    if (String(url).includes("/workflows/")) return Response.json({ workflow_runs: [run] });
    if (String(url).includes("/artifacts?"))
      return Response.json({
        artifacts: [
          {
            name: "twinbox-security-report",
            expired: false,
            archive_download_url: "https://api.github.com/archive",
          },
        ],
      });
    if (String(url) === "https://api.github.com/archive")
      return new Response(null, {
        status: 302,
        headers: { location: "https://storage.example/artifact.zip" },
      });
    if (String(url) === "https://storage.example/artifact.zip") return new Response(archive);
    throw new Error(`Unexpected URL ${url}`);
  };
  try {
    const loaded = await createSecurityReportLoader(directory, "test-token")();
    assert.equal(loaded.report.workflowRunId, "42");
    assert.equal(loaded.error, null);
    assert.equal(seen.at(-1).authorization, undefined);
  } finally {
    global.fetch = originalFetch;
    await fs.rm(directory, { recursive: true, force: true });
  }
});
