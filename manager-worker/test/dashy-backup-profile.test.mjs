import test from "node:test";
import assert from "node:assert/strict";
import { withBackupAdminProfile } from "../../lib/dashy-backup-profile.mjs";

const id = "configure-backup-storage";
const states = new Map([
  [id, { status: "succeeded", outputs: { endpoint: "https://s3.example.com" } }],
]);
test("existing backup installations gain the admin URL without modifying saved answers", () => {
  const profile = {
    mode: "managed-seaweedfs",
    vm: { status: "ready" },
    admin: { url: "https://backup.example.com:8443" },
    secret_access_key: "private",
  };
  const result = withBackupAdminProfile(states, profile);
  assert.equal(
    result.get(id).outputs.seaweedfs_backup_admin_url,
    "https://backup.example.com:8443/"
  );
  assert.equal(result.get(id).status, "succeeded");
  assert.equal(states.get(id).outputs.seaweedfs_backup_admin_url, undefined);
  assert.equal(JSON.stringify([...result]).includes("private"), false);
  assert.deepEqual(withBackupAdminProfile(result, profile), result);
});
test("missing, external, unfinished and invalid admin profiles omit stale links", () => {
  const stale = new Map([
    [
      id,
      { status: "succeeded", outputs: { seaweedfs_backup_admin_url: "https://old.example.com" } },
    ],
  ]);
  for (const profile of [
    null,
    { mode: "external-s3" },
    ...["bad", "http://admin.example.com", "https://user:password@admin.example.com"].map(
      (url) => ({ mode: "managed-seaweedfs", vm: { status: "ready" }, admin: { url } })
    ),
  ]) {
    assert.equal(
      withBackupAdminProfile(stale, profile).get(id).outputs.seaweedfs_backup_admin_url,
      undefined
    );
  }
});
