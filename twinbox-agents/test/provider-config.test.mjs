import test from "node:test";
import assert from "node:assert/strict";
import os from "node:os";
import path from "node:path";
import fs from "node:fs";
import { createProviderConfigStore } from "../src/provider-config.mjs";

function tempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "provider-config-test-"));
}

test("provider-config does not save apiKey in config", () => {
  const dataDir = tempDir();
  const store = createProviderConfigStore(dataDir);

  store.saveConfig({
    kind: "openai-compatible",
    displayName: "Test",
    baseUrl: "http://localhost:8080/v1",
    model: "test-model",
    timeoutMs: 30000,
  });

  store.saveApiKey("sk-secret-key-12345");

  const config = store.getConfig();
  assert.ok(config);
  assert.equal(config.kind, "openai-compatible");
  assert.equal(config.apiKey, undefined);
  assert.equal(config.hasApiKey, undefined);

  assert.ok(store.hasApiKey());
  assert.equal(store.getApiKey(), "sk-secret-key-12345");
});

test("provider-config hasApiKey returns false when no key", () => {
  const dataDir = tempDir();
  const store = createProviderConfigStore(dataDir);

  assert.equal(store.hasApiKey(), false);
  assert.equal(store.getApiKey(), null);
});

test("provider-config getConfig returns null when no config", () => {
  const dataDir = tempDir();
  const store = createProviderConfigStore(dataDir);

  assert.equal(store.getConfig(), null);
});

test("provider-config strips apiKey from saved config", () => {
  const dataDir = tempDir();
  const store = createProviderConfigStore(dataDir);

  store.saveConfig({
    kind: "openai-compatible",
    baseUrl: "http://localhost:8080/v1",
    model: "test",
    apiKey: "should-be-stripped",
  });

  const config = store.getConfig();
  assert.equal(config.apiKey, undefined);
});

test("provider-config reads mounted config path before writable fallback", () => {
  const dataDir = tempDir();
  const mountedConfig = path.join(dataDir, "mounted-provider.json");
  fs.writeFileSync(
    mountedConfig,
    JSON.stringify({ baseUrl: "http://mounted.example/v1", model: "mounted-model" }),
    "utf-8"
  );

  const previousPath = process.env.AGENT_PROVIDER_CONFIG_PATH;
  process.env.AGENT_PROVIDER_CONFIG_PATH = mountedConfig;
  try {
    const store = createProviderConfigStore(dataDir);
    store.saveConfig({ baseUrl: "http://fallback.example/v1", model: "fallback-model" });
    const config = store.getConfig();
    assert.equal(config.baseUrl, "http://mounted.example/v1");
    assert.equal(config.model, "mounted-model");
  } finally {
    if (previousPath === undefined) {
      delete process.env.AGENT_PROVIDER_CONFIG_PATH;
    } else {
      process.env.AGENT_PROVIDER_CONFIG_PATH = previousPath;
    }
  }
});

test("provider-config reads API key from environment before file fallback", () => {
  const dataDir = tempDir();
  const previousKey = process.env.OPENAI_API_KEY;
  process.env.OPENAI_API_KEY = "env-key";
  try {
    const store = createProviderConfigStore(dataDir);
    store.saveApiKey("file-key");
    assert.equal(store.hasApiKey(), true);
    assert.equal(store.getApiKey(), "env-key");
  } finally {
    if (previousKey === undefined) {
      delete process.env.OPENAI_API_KEY;
    } else {
      process.env.OPENAI_API_KEY = previousKey;
    }
  }
});
