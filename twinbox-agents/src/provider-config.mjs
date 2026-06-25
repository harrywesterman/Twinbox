import { existsSync, mkdirSync, readFileSync, writeFileSync, renameSync } from "node:fs";
import { join } from "node:path";

function createProviderConfigStore(dataDir) {
  const effectiveDataDir = process.env.AGENT_DATA_DIR || dataDir || "/data";
  const providerDir = join(effectiveDataDir, "provider");
  const configFile = join(providerDir, "config.json");
  const mountedConfigFile = String(process.env.AGENT_PROVIDER_CONFIG_PATH || "").trim();
  const apiKeyFile = join(providerDir, "api-key");

  function ensureDir() {
    if (!existsSync(providerDir)) {
      mkdirSync(providerDir, { recursive: true });
    }
  }

  function readConfigFile(filePath) {
    if (!filePath || !existsSync(filePath)) {
      return null;
    }
    try {
      return JSON.parse(readFileSync(filePath, "utf-8"));
    } catch {
      return null;
    }
  }

  function getConfig() {
    return readConfigFile(mountedConfigFile) || readConfigFile(configFile);
  }

  function saveConfig(config) {
    ensureDir();
    const stripped = { ...config };
    delete stripped.apiKey;
    const tmpFile = configFile + ".tmp";
    writeFileSync(tmpFile, JSON.stringify(stripped, null, 2), "utf-8");
    renameSync(tmpFile, configFile);
    return stripped;
  }

  function hasApiKey() {
    return Boolean(String(process.env.OPENAI_API_KEY || "").trim() || existsSync(apiKeyFile));
  }

  function getApiKey() {
    const envKey = String(process.env.OPENAI_API_KEY || "").trim();
    if (envKey) {
      return envKey;
    }
    if (!existsSync(apiKeyFile)) {
      return null;
    }
    try {
      return readFileSync(apiKeyFile, "utf-8").trim();
    } catch {
      return null;
    }
  }

  function saveApiKey(key) {
    ensureDir();
    writeFileSync(apiKeyFile, key, { mode: 0o600, encoding: "utf-8" });
  }

  return {
    getConfig,
    saveConfig,
    hasApiKey,
    getApiKey,
    saveApiKey,
  };
}

export { createProviderConfigStore };
