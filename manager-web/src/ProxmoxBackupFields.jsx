import { useEffect, useRef, useState } from "react";

const PLACEMENT_FIELDS = new Set(["pbs_node", "pbs_datastore", "pbs_cache_datastore", "pbs_ip"]);

export function isPbsPlacementField(input) {
  return PLACEMENT_FIELDS.has(input?.id);
}

export default function ProxmoxBackupFields({
  clusterId,
  clusterDraft,
  draft,
  setAnswers,
  onValidity,
}) {
  const [state, setState] = useState({ loading: true, data: null, error: "" });
  const [revision, setRevision] = useState(0);
  const excluded = useRef([]);
  const draftIp = useRef(draft.pbs_ip || "");
  draftIp.current = draft.pbs_ip || "";
  const networkKey = JSON.stringify(clusterDraft || {});

  useEffect(() => {
    let cancelled = false;
    const controller = new AbortController();
    onValidity(false);
    setState({ loading: true, data: null, error: "" });
    fetch("/api/proxmox-backup/discovery", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      signal: controller.signal,
      body: JSON.stringify({
        cluster_id: clusterId || undefined,
        cluster: JSON.parse(networkKey),
        management_ip: window.location.hostname,
        pbs_ip: draftIp.current,
        suggest_ip: !draftIp.current,
        exclude_ips: excluded.current,
      }),
    })
      .then(async (response) => {
        const data = await response.json();
        if (!response.ok) throw new Error(data.error || "PBS discovery failed");
        if (cancelled) return;
        setState({ loading: false, data, error: "" });
        setAnswers((answers) => {
          const current = answers["configure-proxmox-backup-server"] || {};
          const existing = data.existing || {};
          const hosts = data.hosts || [];
          const selectedHost =
            hosts.find((host) => host.node === (existing.node || current.pbs_node)) || hosts[0];
          const stores = selectedHost?.storages || [];
          const next = {
            ...current,
            ...(existing.vm_id
              ? {
                  pbs_node: existing.node,
                  pbs_datastore: existing.datastore,
                  pbs_cache_datastore: existing.cache_datastore,
                  pbs_cpu: existing.cpu,
                  pbs_memory_gb: existing.memory_gb,
                  pbs_system_disk_gb: existing.system_disk_gb,
                  pbs_cache_disk_gb: existing.cache_disk_gb,
                  pbs_ip: existing.ip_address,
                }
              : {}),
          };
          if (!next.pbs_node) next.pbs_node = selectedHost?.node || "";
          if (!stores.some((store) => store.storage === next.pbs_datastore))
            next.pbs_datastore = stores[0]?.storage || "";
          if (!stores.some((store) => store.storage === next.pbs_cache_datastore))
            next.pbs_cache_datastore = stores[0]?.storage || "";
          if (!next.pbs_ip) next.pbs_ip = data.ip || "";
          return { ...answers, "configure-proxmox-backup-server": next };
        });
      })
      .catch((error) => {
        if (!cancelled && error.name !== "AbortError")
          setState({ loading: false, data: null, error: error.message });
      });
    return () => {
      cancelled = true;
      controller.abort();
    };
  }, [clusterId, networkKey, revision, setAnswers, onValidity]);

  const host = state.data?.hosts?.find((entry) => entry.node === draft.pbs_node);
  const valid = Boolean(
    !state.loading &&
    !state.error &&
    host &&
    !host.error &&
    host.storages?.some((entry) => entry.storage === draft.pbs_datastore) &&
    host.storages?.some((entry) => entry.storage === draft.pbs_cache_datastore) &&
    draft.pbs_ip
  );
  useEffect(() => onValidity(valid), [valid, onValidity]);

  function change(field, value) {
    setAnswers((answers) => {
      const current = answers["configure-proxmox-backup-server"] || {};
      const next = { ...current, [field]: value };
      if (field === "pbs_node" && state.data) {
        const nextHost = state.data.hosts.find((entry) => entry.node === value);
        if (!nextHost?.storages.some((entry) => entry.storage === next.pbs_datastore))
          next.pbs_datastore = nextHost?.storages?.[0]?.storage || "";
        if (!nextHost?.storages.some((entry) => entry.storage === next.pbs_cache_datastore))
          next.pbs_cache_datastore = nextHost?.storages?.[0]?.storage || "";
      }
      return { ...answers, "configure-proxmox-backup-server": next };
    });
  }

  return (
    <>
      <label className="wizard-field">
        <span className="wizard-field-label">PBS Proxmox host</span>
        <select
          value={draft.pbs_node || ""}
          disabled={state.loading || Boolean(state.data?.existing)}
          onChange={(event) => change("pbs_node", event.target.value)}
        >
          <option value="">Choose a host</option>
          {(state.data?.hosts || []).map((entry) => (
            <option key={entry.node} value={entry.node} disabled={Boolean(entry.error)}>
              {entry.node} — {Math.floor(entry.free_memory / 1024 ** 3)} GiB RAM free
              {entry.error ? ` — ${entry.error}` : ""}
            </option>
          ))}
        </select>
        <small>The dedicated Debian PBS VM runs on this host.</small>
      </label>
      <label className="wizard-field">
        <span className="wizard-field-label">PBS system datastore</span>
        <select
          value={draft.pbs_datastore || ""}
          disabled={state.loading || !host || Boolean(state.data?.existing)}
          onChange={(event) => change("pbs_datastore", event.target.value)}
        >
          <option value="">Choose a datastore</option>
          {(host?.storages || []).map((entry) => (
            <option key={entry.storage} value={entry.storage}>
              {entry.storage} — {Math.floor(entry.avail / 1024 ** 3)} GiB free
            </option>
          ))}
        </select>
        <small>Stores the Debian system disk.</small>
      </label>
      <label className="wizard-field">
        <span className="wizard-field-label">PBS cache datastore</span>
        <select
          value={draft.pbs_cache_datastore || ""}
          disabled={state.loading || !host || Boolean(state.data?.existing)}
          onChange={(event) => change("pbs_cache_datastore", event.target.value)}
        >
          <option value="">Choose a datastore</option>
          {(host?.storages || []).map((entry) => (
            <option key={entry.storage} value={entry.storage}>
              {entry.storage} — {Math.floor(entry.avail / 1024 ** 3)} GiB free
            </option>
          ))}
        </select>
        <small>Dedicated local cache; PBS never falls back to the system disk.</small>
      </label>
      <label className="wizard-field">
        <span className="wizard-field-label">PBS VM IP</span>
        <input
          value={draft.pbs_ip || ""}
          disabled={Boolean(state.data?.existing)}
          onChange={(event) => change("pbs_ip", event.target.value)}
        />
        <small>Suggested from the cluster subnet and checked again before provisioning.</small>
      </label>
      <div role="status">
        {state.loading && <p>Discovering Proxmox hosts, datastores and a free IP…</p>}
        {state.error && <p className="wizard-network-error">{state.error}</p>}
        {state.data?.ip_error && <p className="wizard-network-error">{state.data.ip_error}</p>}
        <button
          type="button"
          disabled={state.loading}
          onClick={() => {
            if (draft.pbs_ip) excluded.current.push(draft.pbs_ip);
            change("pbs_ip", "");
            setRevision((value) => value + 1);
          }}
        >
          Zoek ander vrij IP
        </button>
        <button
          type="button"
          disabled={state.loading}
          onClick={() => setRevision((value) => value + 1)}
        >
          Retry discovery
        </button>
      </div>
    </>
  );
}
