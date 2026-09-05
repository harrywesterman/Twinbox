import assert from "node:assert/strict";
import test from "node:test";
import { getQuestionSteps } from "../src/question-flow.js";
import { isInputVisible } from "../src/input-visibility.js";

test("backup storage is asked immediately after node provisioning", () => {
  const steps = getQuestionSteps();
  const index = steps.findIndex((step) => step.id === "provision-nodes");
  assert.equal(steps[index + 1].id, "configure-backup-storage");
  const backup = steps[index + 1];
  const secret = backup.inputs.find((input) => input.id === "s3_secret_access_key");
  assert.equal(secret.type, "password");
  assert.equal(secret.sensitive, true);
  assert.equal(secret.required, true);
  assert.equal(isInputVisible(secret, { backup_storage_mode: "external-s3" }), true);
  assert.equal(isInputVisible(secret, { backup_storage_mode: "managed-seaweedfs" }), false);
  const disk = backup.inputs.find((input) => input.id === "seaweedfs_data_disk_gb");
  assert.equal(disk.min, 100);
  assert.equal(disk.default, 500);
  assert.equal(isInputVisible(disk, { backup_storage_mode: "managed-seaweedfs" }), true);
});
