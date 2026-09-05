export function withBackupAdminProfile(states, profile) {
  const result = new Map(states);
  const id = "configure-backup-storage";
  const previous = result.get(id) || {};
  const outputs = { ...previous.outputs };
  delete outputs.seaweedfs_backup_admin_url;
  const url = profile?.admin?.url;
  if (profile?.mode === "managed-seaweedfs" && profile?.vm?.status === "ready" && url) {
    const parsed = URL.parse(url);
    if (parsed?.protocol === "https:" && !parsed.username && !parsed.password) {
      outputs.seaweedfs_backup_admin_url = parsed.href;
    }
  }
  result.set(id, { ...previous, outputs });
  return result;
}
