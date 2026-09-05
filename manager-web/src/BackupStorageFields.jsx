import { useEffect, useRef, useState } from "react";
import { validateBackupIp, validateBackupPlacement } from "../../lib/backup-placement.mjs";
import { mergeBackupDiscovery } from "./backup-storage.js";

export default function BackupStorageFields({
  clusterId,
  clusterDraft,
  draft,
  setAnswers,
  onValidity,
}) {
  const [state, setState] = useState({ loading: true, data: null, error: "" });
  const [revision, setRevision] = useState(0);
  const current = useRef(draft);
  const excluded = useRef([]);
  useEffect(() => {
    current.current = draft;
  }, [draft]);
  const networkKey = JSON.stringify(clusterDraft);
  useEffect(() => {
    let cancelled = false;
    const controller = new AbortController();
    onValidity(false);
    setState({ loading: true, data: null, error: "" });
    fetch("/api/backup-storage/discovery", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      signal: controller.signal,
      body: JSON.stringify({
        cluster_id: clusterId || undefined,
        cluster: JSON.parse(networkKey),
        management_ip: window.location.hostname,
        suggest_ip: !current.current.seaweedfs_ip,
        exclude_ips: excluded.current,
      }),
    })
      .then(async (response) => {
        const data = await response.json();
        if (!response.ok) throw new Error(data.error || "Backup discovery failed");
        if (cancelled) return;
        setState({ loading: false, data, error: "" });
        setAnswers((answers) => ({
          ...answers,
          "configure-backup-storage": mergeBackupDiscovery(
            answers["configure-backup-storage"] || {},
            data
          ),
        }));
      })
      .catch((error) => {
        if (!cancelled) setState({ loading: false, data: null, error: error.message });
      });
    return () => {
      cancelled = true;
      controller.abort();
    };
  }, [clusterId, networkKey, revision, setAnswers, onValidity]);

  let error = state.error;
  if (!state.loading && state.data) {
    try {
      validateBackupPlacement(state.data.hosts, draft, state.data.existing);
      validateBackupIp(state.data.network, draft.seaweedfs_ip, new Set(state.data.reserved_ips));
    } catch (failure) {
      error = failure.message;
    }
  }
  const valid = !state.loading && Boolean(state.data) && !error;
  useEffect(() => {
    onValidity(valid);
  }, [valid, onValidity]);
  const host = state.data?.hosts.find((h) => h.node === draft.seaweedfs_node);
  const locked = Boolean(state.data?.existing);
  function change(field, value) {
    setAnswers((answers) => {
      let next = { ...answers["configure-backup-storage"], [field]: value };
      if (field === "seaweedfs_node" && state.data) next = mergeBackupDiscovery(next, state.data);
      return { ...answers, "configure-backup-storage": next };
    });
  }
  return (
    <>
      <label className="wizard-field">
        {" "}
        <span className="wizard-field-label">SeaweedFS Proxmox host</span>
        <select
          value={draft.seaweedfs_node || ""}
          disabled={state.loading || locked}
          onChange={(e) => change("seaweedfs_node", e.target.value)}
        >
          <option value="">Choose a host</option>
          {draft.seaweedfs_node &&
            !state.data?.hosts.some((h) => h.node === draft.seaweedfs_node) && (
              <option value={draft.seaweedfs_node}>{draft.seaweedfs_node} — unavailable</option>
            )}
          {state.data?.hosts.map((h) => (
            <option key={h.node} value={h.node} disabled={Boolean(h.error)}>
              {h.node} — {Math.floor(h.free_memory / 1024 ** 3)} GiB RAM free
              {h.error ? ` — ${h.error}` : ""}
            </option>
          ))}
        </select>
        <small>The dedicated backup VM runs on this host.</small>
      </label>
      <label className="wizard-field">
        <span className="wizard-field-label">SeaweedFS Proxmox datastore</span>
        <select
          value={draft.seaweedfs_datastore || ""}
          disabled={state.loading || locked}
          onChange={(e) => change("seaweedfs_datastore", e.target.value)}
        >
          <option value="">Choose a datastore</option>
          {draft.seaweedfs_datastore &&
            !host?.storages.some((s) => s.storage === draft.seaweedfs_datastore) && (
              <option value={draft.seaweedfs_datastore}>
                {draft.seaweedfs_datastore} — unavailable
              </option>
            )}
          {host?.storages.map((s) => (
            <option key={s.storage} value={s.storage}>
              {s.storage} — {Math.floor(s.avail / 1024 ** 3)} GiB free
            </option>
          ))}
        </select>
        <small>Capacity includes an additional 20 GiB system disk.</small>
      </label>
      <label className="wizard-field">
        <span className="wizard-field-label">SeaweedFS data disk (GiB)</span>
        <input
          type="number"
          min="100"
          value={draft.seaweedfs_data_disk_gb ?? 500}
          disabled={locked}
          onChange={(e) => change("seaweedfs_data_disk_gb", e.target.value)}
        />
      </label>
      <label className="wizard-field">
        <span className="wizard-field-label">SeaweedFS VM IP</span>
        <input
          value={draft.seaweedfs_ip || ""}
          disabled={locked}
          onChange={(e) => change("seaweedfs_ip", e.target.value)}
        />
        <small>Proposed from the cluster network; checked again before creating the VM.</small>
      </label>
      <div role="status">
        {state.loading && <p>Discovering Proxmox hosts, datastores and IP address…</p>}
        {error && <p className="wizard-network-error">{error}</p>}
        {state.data?.ip_error && <p>{state.data.ip_error}</p>}
        {locked ? (
          <p>Existing backup VM: placement and address are preserved.</p>
        ) : (
          <button
            type="button"
            disabled={state.loading}
            onClick={() => {
              if (draft.seaweedfs_ip) excluded.current.push(draft.seaweedfs_ip);
              current.current = { ...draft, seaweedfs_ip: "" };
              change("seaweedfs_ip", "");
              setRevision((n) => n + 1);
            }}
          >
            Zoek ander vrij IP
          </button>
        )}
        <button type="button" disabled={state.loading} onClick={() => setRevision((n) => n + 1)}>
          Retry discovery
        </button>
      </div>
    </>
  );
}
