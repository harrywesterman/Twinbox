import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

test("health endpoint exposes the running manager image tag", async (t) => {
  const previousDataDir = process.env.MANAGER_DATA_DIR;
  const previousImageTag = process.env.TWINBOX_IMAGE_TAG;
  const previousTestFlag = process.env.MANAGER_API_TEST;
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "twinbox-health-"));

  process.env.MANAGER_API_TEST = "true";
  process.env.MANAGER_DATA_DIR = tempRoot;
  process.env.TWINBOX_IMAGE_TAG = "sha-abcdef1";

  const { app } = await import(`../src/server.js?health=${Date.now()}`);
  const server = app.listen(0);

  t.after(async () => {
    await new Promise((resolve, reject) => {
      server.close((error) => (error ? reject(error) : resolve()));
    });
    fs.rmSync(tempRoot, { recursive: true, force: true });
    if (previousDataDir === undefined) {
      delete process.env.MANAGER_DATA_DIR;
    } else {
      process.env.MANAGER_DATA_DIR = previousDataDir;
    }
    if (previousImageTag === undefined) {
      delete process.env.TWINBOX_IMAGE_TAG;
    } else {
      process.env.TWINBOX_IMAGE_TAG = previousImageTag;
    }
    if (previousTestFlag === undefined) {
      delete process.env.MANAGER_API_TEST;
    } else {
      process.env.MANAGER_API_TEST = previousTestFlag;
    }
  });

  const address = server.address();
  const response = await fetch(`http://127.0.0.1:${address.port}/api/health`);
  const body = await response.json();

  assert.equal(response.status, 200);
  assert.equal(body.ok, true);
  assert.equal(body.image_tag, "sha-abcdef1");
  assert.match(body.time, /^\d{4}-\d{2}-\d{2}T/);
});
