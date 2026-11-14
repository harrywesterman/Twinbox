import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { prepareGatusInputs } from "../../lib/gatus-notifications.mjs";
import { readItemRecord } from "../../lib/secrets/filesystem-store.mjs";
import {
  buildCatalogResponse,
  partitionStepInputs,
  validateStepInputs,
} from "../src/lib/catalog.js";

test("Gatus notification inputs persist privately, retain blank secrets, and tests do not change settings", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "gatus-secrets-"));
  const env = { TWINBOX_BOOTSTRAP_DIR: directory };
  try {
    const inputs = { telegram_enabled: true };
    const secrets = { telegram_token: "private-token", telegram_chat_id: "private-chat" };
    assert.deepEqual(prepareGatusInputs(inputs, secrets, "prd", env), inputs);
    assert.deepEqual(prepareGatusInputs(inputs, { telegram_token: "" }, "prd", env), inputs);
    const ref = { scope: "cluster", item: "gatus-notifications", cluster_id: "prd" };
    assert.equal(readItemRecord(env, ref).telegram_token, "private-token");
    assert.deepEqual(
      prepareGatusInputs({ test_only: true, test_provider: "telegram" }, {}, "prd", env),
      { test_only: true, test_provider: "telegram" }
    );
    assert.equal(readItemRecord(env, ref).telegram_token, "private-token");
    assert.throws(() => prepareGatusInputs({ pushover_enabled: true }, {}, "prd", env));
    assert.deepEqual(prepareGatusInputs({ telegram_enabled: false }, {}, "prd", env), {
      telegram_enabled: false,
    });
    assert.equal(readItemRecord(env, ref).telegram_token, "private-token");
    const stat = fs.statSync(
      path.join(directory, "secrets/cluster/prd/gatus-notifications/metadata.json")
    );
    assert.equal(stat.mode & 0o777, 0o600);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("real notification catalog declares every credential sensitive and only safe flags enter jobs", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "gatus-catalog-"));
  try {
    const dirs = {
      clusters: path.join(directory, "clusters"),
      stepState: path.join(directory, "step-state"),
      jobs: path.join(directory, "jobs"),
    };
    Object.values(dirs).forEach((dir) => fs.mkdirSync(dir, { recursive: true }));
    const catalog = buildCatalogResponse({
      workspaceRoot: path.resolve(import.meta.dirname, "../.."),
      dirs,
    });
    const step = catalog.stepsById.get("configure-gatus-notifications");
    const values = { telegram_enabled: true, telegram_token: "secret", telegram_chat_id: "chat" };
    const validated = validateStepInputs(step, values);
    assert.equal(validated.ok, true);
    const { publicInputs, secretFields } = partitionStepInputs(step, validated.value);
    assert.equal(JSON.stringify(publicInputs).includes("secret"), false);
    assert.equal(secretFields.telegram_token, "secret");
    assert.equal(step.ingress_route, "netbird");
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
