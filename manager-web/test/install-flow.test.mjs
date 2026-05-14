import test from "node:test";
import assert from "node:assert/strict";

import {
  buildInstallRefreshFailureNotice,
  buildQueueFailureNotice,
  normalizeJobResult,
} from "../src/install-flow.js";

test("normalizeJobResult accepts raw jobs and wrapped job envelopes", () => {
  const rawJob = {
    id: "job_123",
    status: "succeeded",
    error: null,
  };

  assert.equal(normalizeJobResult(rawJob), rawJob);
  assert.equal(normalizeJobResult({ job: rawJob }), rawJob);
  assert.equal(normalizeJobResult(null), null);
});

test("install flow notices distinguish queue failures from refresh failures", () => {
  assert.equal(
    buildQueueFailureNotice("Deploy Talos Cluster"),
    "Could not queue Deploy Talos Cluster."
  );
  assert.equal(
    buildInstallRefreshFailureNotice("Deploy Talos Cluster"),
    "Deploy Talos Cluster completed successfully, but Twinbox could not refresh the wizard state."
  );
});
