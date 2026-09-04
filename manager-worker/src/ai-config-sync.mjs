const AI_SECRET_NAMES = [
  "TWINBOX_AGENT_INTERNAL_TOKEN",
  "OPENAI_API_KEY",
  "PAPERLESS_AI_LLM_API_KEY",
];

const AI_SECRET_ASSIGNMENT = new RegExp(
  `(${AI_SECRET_NAMES.join("|")})(["']?\\s*[:=]\\s*["']?)([^\\s,"'}]+)`,
  "g"
);

export function redactAiConfigLine(line) {
  return String(line ?? "").replace(AI_SECRET_ASSIGNMENT, "$1$2***");
}

export function isAiConfigSyncJobType(type) {
  return type === "sync_ai_config" || type === "sync_agent_config";
}
