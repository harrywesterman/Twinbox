import { validateBackupPlacement } from "../../lib/backup-placement.mjs";

export function mergeBackupDiscovery(draft, data) {
  if (data.existing)
    return {
      ...draft,
      seaweedfs_node: data.existing.node,
      seaweedfs_datastore: data.existing.datastore,
      seaweedfs_ip: data.existing.ip_address,
      seaweedfs_data_disk_gb: data.existing.data_disk_gb,
    };
  const next = { ...draft, seaweedfs_data_disk_gb: draft.seaweedfs_data_disk_gb ?? 500 };
  if (!next.seaweedfs_node) {
    next.seaweedfs_node =
      data.hosts.find((host) =>
        host.storages.some((disk) => {
          try {
            validateBackupPlacement([host], {
              ...next,
              seaweedfs_node: host.node,
              seaweedfs_datastore: disk.storage,
            });
            return true;
          } catch {
            return false;
          }
        })
      )?.node || "";
  }
  const host = data.hosts.find((h) => h.node === next.seaweedfs_node);
  if (host && !host.storages.some((s) => s.storage === next.seaweedfs_datastore)) {
    next.seaweedfs_datastore = host.storages[0]?.storage || "";
  }
  if (!next.seaweedfs_ip) next.seaweedfs_ip = data.ip || "";
  return next;
}
