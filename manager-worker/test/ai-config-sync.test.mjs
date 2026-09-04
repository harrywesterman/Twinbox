import assert from "node:assert/strict";
import test from "node:test";

import { isAiConfigSyncJobType, redactAiConfigLine } from "../src/ai-config-sync.mjs";

test("isAiConfigSyncJobType accepts current and legacy queue types", () => {
  assert.equal(isAiConfigSyncJobType("sync_ai_config"), true);
  assert.equal(isAiConfigSyncJobType("sync_agent_config"), true);
  assert.equal(isAiConfigSyncJobType("run_step"), false);
});

test("redactAiConfigLine redacts shell-style AI secrets", () => {
  const line =
    "OPENAI_API_KEY=central-secret PAPERLESS_AI_LLM_API_KEY=paperless-secret TWINBOX_AGENT_INTERNAL_TOKEN=agent-secret";

  const redacted = redactAiConfigLine(line);

  assert.equal(
    redacted,
    "OPENAI_API_KEY=*** PAPERLESS_AI_LLM_API_KEY=*** TWINBOX_AGENT_INTERNAL_TOKEN=***"
  );
  assert.doesNotMatch(redacted, /central-secret|paperless-secret|agent-secret/);
});

test("redactAiConfigLine redacts JSON-style AI secrets", () => {
  const line = '{"OPENAI_API_KEY":"central-secret","status":"failed"}';

  const redacted = redactAiConfigLine(line);

  assert.equal(redacted, '{"OPENAI_API_KEY":"***","status":"failed"}');
  assert.doesNotMatch(redacted, /central-secret/);
});
