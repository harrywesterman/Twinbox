import test from "node:test";
import assert from "node:assert/strict";

import { isInputVisible, omitSensitiveAnswers } from "../src/input-visibility.js";

test("conditional backup inputs follow the selected storage mode", () => {
  const external = { visible_when: { input: "backup_storage_mode", equals: "external-s3" } };
  const managed = {
    visible_when: { input: "backup_storage_mode", equals: "managed-seaweedfs" },
  };

  assert.equal(isInputVisible(external, { backup_storage_mode: "external-s3" }), true);
  assert.equal(isInputVisible(managed, { backup_storage_mode: "external-s3" }), false);
  assert.equal(isInputVisible(external, { backup_storage_mode: "managed-seaweedfs" }), false);
  assert.equal(isInputVisible(managed, { backup_storage_mode: "managed-seaweedfs" }), true);
});

test("wizard persistence omits sensitive S3 credentials", () => {
  const catalog = {
    categories: [
      {
        steps: [
          {
            id: "backup",
            inputs: [
              { id: "endpoint" },
              { id: "access", sensitive: true },
              { id: "secret", sensitive: true },
            ],
          },
        ],
      },
    ],
  };
  assert.deepEqual(
    omitSensitiveAnswers(catalog, { backup: { endpoint: "https://s3", access: "a", secret: "s" } }),
    {
      backup: { endpoint: "https://s3" },
    }
  );
});
