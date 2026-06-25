import test from "node:test";
import assert from "node:assert/strict";
import { isZulipConfigured, postCoordinatorMessage } from "../src/zulip-client.mjs";

const ZULIP_ENV_KEYS = ["ZULIP_BASE_URL", "ZULIP_BOT_EMAIL", "ZULIP_BOT_API_KEY", "ZULIP_STREAM"];

async function withZulipEnv(env, fn) {
  const previousEnv = Object.fromEntries(ZULIP_ENV_KEYS.map((key) => [key, process.env[key]]));
  const previousFetch = globalThis.fetch;
  for (const key of ZULIP_ENV_KEYS) {
    if (env[key] === undefined) {
      delete process.env[key];
    } else {
      process.env[key] = env[key];
    }
  }
  try {
    await fn();
  } finally {
    for (const [key, value] of Object.entries(previousEnv)) {
      if (value === undefined) {
        delete process.env[key];
      } else {
        process.env[key] = value;
      }
    }
    globalThis.fetch = previousFetch;
  }
}

test("postCoordinatorMessage skips when Zulip is not configured", async () => {
  await withZulipEnv({}, async () => {
    assert.equal(isZulipConfigured(), false);
    const result = await postCoordinatorMessage({ topic: "AI beheerteam", content: "Hallo" });
    assert.deepEqual(result, { skipped: true });
  });
});

test("postCoordinatorMessage posts a redacted stream message", async () => {
  await withZulipEnv(
    {
      ZULIP_BASE_URL: "https://zulip.example.test/",
      ZULIP_BOT_EMAIL: "olivia-ops-bot@zulip.example.test",
      ZULIP_BOT_API_KEY: "zulip-secret",
      ZULIP_STREAM: "Twinbox AI",
    },
    async () => {
      let observedUrl = "";
      let observedHeaders = {};
      let observedBody = "";
      globalThis.fetch = async (url, options) => {
        observedUrl = url;
        observedHeaders = options.headers;
        observedBody = options.body;
        return {
          ok: true,
          json: async () => ({ result: "success", id: 123 }),
        };
      };

      const result = await postCoordinatorMessage({
        topic: "AI beheerteam",
        content: "token=super-secret status ok",
      });

      assert.equal(result.result, "success");
      assert.equal(observedUrl, "https://zulip.example.test/api/v1/messages");
      assert.equal(observedHeaders["Content-Type"], "application/x-www-form-urlencoded");

      const body = new URLSearchParams(observedBody);
      assert.equal(body.get("type"), "stream");
      assert.equal(body.get("to"), "Twinbox AI");
      assert.equal(body.get("topic"), "AI beheerteam");
      assert.match(body.get("content"), /TOKEN_REDACTED/);
      assert.doesNotMatch(body.get("content"), /super-secret/);
    }
  );
});
