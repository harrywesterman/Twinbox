import crypto from "crypto";
import fs from "fs";
import path from "path";

import { readJsonIfExists, writeJson } from "./common.js";
import { queueJob } from "./jobs.js";
import { globalSecretPath } from "../../../lib/secrets/filesystem-store.mjs";

function agentsProviderPath(dataRoot) {
  return path.join(dataRoot, "agents", "provider.json");
}

function agentSecretsPath(runtimeEnv = process.env) {
  return globalSecretPath(runtimeEnv, "twinbox-agents");
}

function readAgentSecrets(runtimeEnv = process.env) {
  return readJsonIfExists(agentSecretsPath(runtimeEnv)) || {};
}

function writeAgentSecrets(runtimeEnv = process.env, secrets) {
  writeJson(agentSecretsPath(runtimeEnv), secrets);
}

function dataRootFromDirs(dirs) {
  return path.dirname(dirs.clusters);
}

function clusterUpdatedAt(cluster) {
  return String(cluster?.updated_at || cluster?.created_at || "");
}

export function readAgentProviderConfig(dirs) {
  const file = agentsProviderPath(dataRootFromDirs(dirs));
  if (!fs.existsSync(file)) {
    return null;
  }
  return readJsonIfExists(file);
}

export function writeAgentProviderConfig(dirs, config) {
  const safe = { ...config };
  delete safe.apiKey;
  writeJson(agentsProviderPath(dataRootFromDirs(dirs)), safe);
}

export function normalizeOpenAICompatibleProvider(input) {
  const baseUrl =
    typeof input?.baseUrl === "string" ? input.baseUrl.trim().replace(/\/+$/, "") : "";
  const model = typeof input?.model === "string" ? input.model.trim() : "";
  const displayName = typeof input?.displayName === "string" ? input.displayName.trim() : "";
  const timeoutMs = Number.isFinite(Number(input?.timeoutMs))
    ? Math.max(1000, Number(input.timeoutMs))
    : 60000;

  const errors = [];

  if (!baseUrl) {
    errors.push("baseUrl is required");
  } else if (!/^https?:\/\//.test(baseUrl)) {
    errors.push("baseUrl must be an absolute http or https URL");
  }

  if (!model) {
    errors.push("model is required");
  }

  if (errors.length > 0) {
    return { ok: false, error: errors.join("; ") };
  }

  return {
    ok: true,
    value: {
      displayName,
      baseUrl,
      model,
      timeoutMs,
    },
  };
}

export function resolveAgentProviderTestApiKey(input, storedApiKey = null) {
  const apiKey = typeof input?.apiKey === "string" ? input.apiKey.trim() : "";
  if (apiKey) {
    return apiKey;
  }
  return input?.useStoredApiKey === true ? storedApiKey || null : null;
}

export function writeAgentEndpointSecret(runtimeEnv, apiKey) {
  const secrets = readAgentSecrets(runtimeEnv);
  secrets.OPENAI_API_KEY = apiKey;
  writeAgentSecrets(runtimeEnv, secrets);
}

export function clearAgentEndpointSecret(runtimeEnv) {
  const secrets = readAgentSecrets(runtimeEnv);
  delete secrets.OPENAI_API_KEY;
  writeAgentSecrets(runtimeEnv, secrets);
}

export function ensureAgentInternalToken(runtimeEnv) {
  const secrets = readAgentSecrets(runtimeEnv);
  if (!secrets.TWINBOX_AGENT_INTERNAL_TOKEN) {
    secrets.TWINBOX_AGENT_INTERNAL_TOKEN = crypto.randomBytes(32).toString("base64url");
  }
  writeAgentSecrets(runtimeEnv, secrets);
  return secrets.TWINBOX_AGENT_INTERNAL_TOKEN;
}

export function queueSharedAiConfigSync(dirs, cluster, payload) {
  return queueJob(dirs, "sync_ai_config", cluster, payload);
}

export function queueAgentConfigSync(dirs, cluster, payload) {
  return queueSharedAiConfigSync(dirs, cluster, payload);
}

export function readLatestAgentCluster(dirs) {
  if (!fs.existsSync(dirs.clusters)) {
    return null;
  }

  const clusters = fs
    .readdirSync(dirs.clusters)
    .filter((entry) => entry.endsWith(".json"))
    .map((entry) => readJsonIfExists(path.join(dirs.clusters, entry)))
    .filter((cluster) => cluster?.id)
    .sort((left, right) => {
      const byUpdatedAt = clusterUpdatedAt(right).localeCompare(clusterUpdatedAt(left));
      return byUpdatedAt || String(left.id).localeCompare(String(right.id));
    });

  return clusters[0] || null;
}

export function queueAgentConfigSyncForLatestCluster(dirs, payload = {}) {
  const cluster = readLatestAgentCluster(dirs);
  return queueSharedAiConfigSync(dirs, cluster?.id || "", {
    ...payload,
    cluster_id: cluster?.id || null,
    cluster_instance_id: cluster?.cluster_instance_id || cluster?.instance_id || null,
    cluster: cluster || null,
  });
}

export function hasAgentApiKey(_dirs) {
  const secrets = readAgentSecrets(process.env);
  return Boolean(secrets.OPENAI_API_KEY);
}

export function readAgentEndpointSecret(_dirs) {
  return readAgentSecrets(process.env).OPENAI_API_KEY || null;
}

export function resolveAgentSecretsPath(runtimeEnv = process.env) {
  return agentSecretsPath(runtimeEnv);
}
