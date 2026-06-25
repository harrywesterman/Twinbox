import test from "node:test";
import assert from "node:assert/strict";
import fs from "fs";
import os from "os";
import path from "path";

import {
  clearAgentEndpointSecret,
  ensureAgentInternalToken,
  hasAgentApiKey,
  normalizeOpenAICompatibleProvider,
  queueAgentConfigSyncForLatestCluster,
  readAgentEndpointSecret,
  resolveAgentProviderTestApiKey,
  resolveAgentSecretsPath,
  writeAgentEndpointSecret,
} from "../src/lib/agents.js";

test("normalizeOpenAICompatibleProvider validates baseUrl", () => {
  const result = normalizeOpenAICompatibleProvider({
    baseUrl: "https://ai.example.com/v1",
    model: "gpt-4o",
  });
  assert.ok(result.ok);
  assert.equal(result.value.baseUrl, "https://ai.example.com/v1");
  assert.equal(result.value.model, "gpt-4o");
  assert.equal(result.value.timeoutMs, 60000);
});

test("normalizeOpenAICompatibleProvider rejects missing model", () => {
  const result = normalizeOpenAICompatibleProvider({ baseUrl: "https://example.com/v1" });
  assert.ok(!result.ok);
  assert.ok(result.error.includes("model"));
});

test("normalizeOpenAICompatibleProvider rejects invalid baseUrl", () => {
  const r1 = normalizeOpenAICompatibleProvider({ baseUrl: "not-a-url", model: "test" });
  assert.ok(!r1.ok);
  assert.ok(r1.error.includes("baseUrl"));

  const r2 = normalizeOpenAICompatibleProvider({ baseUrl: "/relative", model: "test" });
  assert.ok(!r2.ok);
  assert.ok(r2.error.includes("baseUrl"));
});

test("normalizeOpenAICompatibleProvider rejects empty model", () => {
  const r1 = normalizeOpenAICompatibleProvider({ baseUrl: "https://example.com/v1", model: "" });
  assert.ok(!r1.ok);
  const r2 = normalizeOpenAICompatibleProvider({ baseUrl: "https://example.com/v1", model: "   " });
  assert.ok(!r2.ok);
});

test("normalizeOpenAICompatibleProvider never returns apiKey in value", () => {
  const result = normalizeOpenAICompatibleProvider({
    baseUrl: "https://example.com/v1",
    model: "test",
    apiKey: "sk-secret",
  });
  assert.ok(result.ok);
  assert.equal(result.value.apiKey, undefined);
});

test("normalizeOpenAICompatibleProvider strips trailing slash", () => {
  const result = normalizeOpenAICompatibleProvider({
    baseUrl: "https://example.com/v1/",
    model: "test",
  });
  assert.ok(result.ok);
  assert.equal(result.value.baseUrl, "https://example.com/v1");
});

test("normalizeOpenAICompatibleProvider defaults timeoutMs", () => {
  const result = normalizeOpenAICompatibleProvider({
    baseUrl: "https://example.com/v1",
    model: "test",
  });
  assert.ok(result.ok);
  assert.equal(result.value.timeoutMs, 60000);
});

test("normalizeOpenAICompatibleProvider accepts custom timeoutMs", () => {
  const result = normalizeOpenAICompatibleProvider({
    baseUrl: "https://example.com/v1",
    model: "test",
    timeoutMs: 30000,
  });
  assert.ok(result.ok);
  assert.equal(result.value.timeoutMs, 30000);
});

test("resolveAgentProviderTestApiKey does not reuse stored key by default", () => {
  assert.equal(
    resolveAgentProviderTestApiKey({ apiKey: "", useStoredApiKey: false }, "stored-key"),
    null
  );
  assert.equal(resolveAgentProviderTestApiKey({}, "stored-key"), null);
  assert.equal(
    resolveAgentProviderTestApiKey({ apiKey: "  explicit-key  " }, "stored-key"),
    "explicit-key"
  );
  assert.equal(
    resolveAgentProviderTestApiKey({ useStoredApiKey: true }, "stored-key"),
    "stored-key"
  );
});

test("agent secrets use TWINBOX_BOOTSTRAP_DIR, not manager-data", () => {
  const bootstrapDir = fs.mkdtempSync(path.join(os.tmpdir(), "twinbox-agent-bootstrap-"));
  const previousBootstrap = process.env.TWINBOX_BOOTSTRAP_DIR;
  process.env.TWINBOX_BOOTSTRAP_DIR = bootstrapDir;

  try {
    const token = ensureAgentInternalToken(process.env);
    writeAgentEndpointSecret(process.env, "local-key");

    const expectedPath = path.join(bootstrapDir, "secrets", "global", "twinbox-agents.json");
    assert.equal(resolveAgentSecretsPath(process.env), expectedPath);
    assert.ok(fs.existsSync(expectedPath));
    assert.ok(token);
    assert.equal(hasAgentApiKey({}), true);
    assert.equal(readAgentEndpointSecret({}), "local-key");

    clearAgentEndpointSecret(process.env);
    assert.equal(hasAgentApiKey({}), false);
    assert.equal(readAgentEndpointSecret({}), null);
  } finally {
    if (previousBootstrap === undefined) {
      delete process.env.TWINBOX_BOOTSTRAP_DIR;
    } else {
      process.env.TWINBOX_BOOTSTRAP_DIR = previousBootstrap;
    }
    fs.rmSync(bootstrapDir, { recursive: true, force: true });
  }
});

test("queueAgentConfigSyncForLatestCluster includes latest cluster context", () => {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "twinbox-agent-queue-"));
  const dirs = {
    clusters: path.join(tempRoot, "clusters"),
    jobs: path.join(tempRoot, "jobs"),
    logs: path.join(tempRoot, "logs"),
    pending: path.join(tempRoot, "queue", "pending"),
  };
  for (const dir of Object.values(dirs)) {
    fs.mkdirSync(dir, { recursive: true });
  }

  try {
    fs.writeFileSync(
      path.join(dirs.clusters, "old-cluster.json"),
      JSON.stringify({
        id: "old-cluster",
        cluster_instance_id: "old-instance",
        updated_at: "2026-01-01T00:00:00.000Z",
      })
    );
    fs.writeFileSync(
      path.join(dirs.clusters, "new-cluster.json"),
      JSON.stringify({
        id: "new-cluster",
        cluster_instance_id: "new-instance",
        updated_at: "2026-02-01T00:00:00.000Z",
      })
    );

    const job = queueAgentConfigSyncForLatestCluster(dirs, { reason: "test" });

    assert.equal(job.cluster_id, "new-cluster");
    assert.equal(job.cluster_instance_id, "new-instance");
    assert.equal(job.payload.cluster_id, "new-cluster");
    assert.equal(job.payload.cluster_instance_id, "new-instance");
    assert.equal(job.payload.reason, "test");
  } finally {
    fs.rmSync(tempRoot, { recursive: true, force: true });
  }
});
