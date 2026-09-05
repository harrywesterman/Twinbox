import fs from "node:fs";
import path from "node:path";
import { clusterSecretDir } from "../../lib/secrets/filesystem-store.mjs";
import {
  backupHosts,
  reservedBackupIps,
  validateBackupIp,
  validateBackupPlacement,
} from "../../lib/backup-placement.mjs";

try {
  const data = JSON.parse(fs.readFileSync(0, "utf8"));
  const hosts = backupHosts(data);
  const host = validateBackupPlacement(hosts, data.inputs, data.existing);
  const clusterDir = path.join(process.env.MANAGER_DATA_DIR || "/data", "clusters");
  const clusters = fs.existsSync(clusterDir)
    ? fs
        .readdirSync(clusterDir)
        .filter((file) => file.endsWith(".json"))
        .map((file) => JSON.parse(fs.readFileSync(path.join(clusterDir, file), "utf8")))
    : [];
  const backupIps = clusters
    .filter((c) => c.id !== data.cluster.id)
    .map((c) => {
      const file = path.join(
        clusterSecretDir(process.env, c.id, "backup-storage"),
        "metadata.json"
      );
      return fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, "utf8"))?.vm?.ip_address : null;
    });
  const reserved = reservedBackupIps(
    [...clusters, ...(data.other_clusters || []), data.cluster],
    process.env.MANAGEMENT_VM_IP,
    backupIps
  );
  validateBackupIp(data.cluster, data.inputs.seaweedfs_ip, reserved);
  process.stdout.write(host.file_datastore);
} catch (error) {
  process.stderr.write(`SeaweedFS preflight: ${error.message}\n`);
  process.exitCode = 1;
}
