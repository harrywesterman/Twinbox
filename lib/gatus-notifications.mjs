import { readItemRecord, writeItemRecord } from "./secrets/filesystem-store.mjs";
import { mergeGatusCredentials, validateGatusNotifications } from "./gatus-config.mjs";

export function prepareGatusInputs(
  publicInputs,
  secretFields,
  clusterId,
  runtimeEnv = process.env
) {
  const ref = { scope: "cluster", item: "gatus-notifications", cluster_id: clusterId };
  const existing = readItemRecord(runtimeEnv, ref, { clusterId }) || {};
  if (publicInputs.test_only)
    return { ...existing.settings, test_only: true, test_provider: publicInputs.test_provider };
  const credentials = { ...existing, ...mergeGatusCredentials({}, secretFields) };
  validateGatusNotifications(publicInputs, credentials);
  writeItemRecord(runtimeEnv, ref, credentials, { clusterId });
  return publicInputs;
}
