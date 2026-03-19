import { useEffect, useMemo, useState } from 'react';
import './App.css';

const defaultForm = {
  name: 'twinbox-cluster',
  controlplane_count: 1,
  worker_count: 2,
  cpu_cores: 2,
  memory_mb: 4096,
  disk_gb: 20,
  bridge: 'vmbr0',
  start_vmid: 200,
  vip_ip: '192.168.1.50',
  start_ip: '192.168.1.51',
};

function isIPv4(value) {
  if (typeof value !== 'string') return false;
  const parts = value.split('.');
  if (parts.length !== 4) return false;
  return parts.every((part) => /^\d+$/.test(part) && Number(part) >= 0 && Number(part) <= 255);
}

function formatState(value, fallback) {
  if (!value) return fallback;
  return value
    .toString()
    .replace(/[_-]+/g, ' ')
    .replace(/\b\w/g, (char) => char.toUpperCase());
}

function toneForState(value) {
  if (!value) return 'neutral';

  const normalized = value.toString().toLowerCase();
  if (normalized === 'idle' || normalized === 'not started' || normalized === 'not_started' || normalized === 'not-started') {
    return 'neutral';
  }
  if (normalized.includes('fail') || normalized.includes('error')) return 'danger';
  if (normalized.includes('complete') || normalized.includes('ready') || normalized.includes('success')) return 'success';
  if (
    normalized.includes('running') ||
    normalized.includes('queue') ||
    normalized.includes('bootstrap') ||
    normalized.includes('provision') ||
    normalized.includes('start')
  ) {
    return 'active';
  }
  return 'neutral';
}

function App() {
  const [form, setForm] = useState(defaultForm);
  const [clusterId, setClusterId] = useState('');
  const [jobId, setJobId] = useState('');
  const [job, setJob] = useState(null);
  const [logs, setLogs] = useState([]);
  const [cluster, setCluster] = useState(null);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [ipSuggestion, setIpSuggestion] = useState('');

  const canBootstrap = useMemo(() => {
    if (!cluster) return false;
    return Array.isArray(cluster.controlplane_ips) && cluster.controlplane_ips.length > 0;
  }, [cluster]);

  const jobStatusLabel = formatState(job?.status, jobId ? 'Queued' : 'Idle');
  const clusterStatusLabel = formatState(cluster?.status, clusterId ? 'Preparing' : 'Not started');
  const currentStepLabel = formatState(job?.step, jobId ? 'Waiting for worker' : 'No active job');
  const latestLogLine = logs.length ? logs[logs.length - 1].line : 'Awaiting command output from the worker.';
  const logOutput = logs.length ? logs.map((entry) => entry.line).join('\n') : 'No logs yet.';

  const heroMetrics = [
    {
      label: 'Cluster',
      value: clusterId || 'Not started',
      tone: clusterId ? toneForState(cluster?.status) : 'neutral',
      chip: clusterStatusLabel,
    },
    {
      label: 'Active Job',
      value: jobId || 'No job yet',
      tone: jobId ? toneForState(job?.status) : 'neutral',
      chip: jobStatusLabel,
    },
    {
      label: 'Job Status',
      value: jobStatusLabel,
      tone: toneForState(job?.status),
      chip: currentStepLabel,
    },
    {
      label: 'Cluster State',
      value: clusterStatusLabel,
      tone: toneForState(cluster?.status),
      chip: canBootstrap ? 'Bootstrap ready' : 'Awaiting control planes',
    },
  ];

  const statusDetails = [
    { label: 'Cluster ID', value: clusterId || '-' },
    { label: 'Job ID', value: jobId || '-' },
    { label: 'Status', value: jobStatusLabel },
    { label: 'Step', value: currentStepLabel },
    { label: 'Result', value: clusterStatusLabel },
    { label: 'Controlplane IPs', value: (cluster?.controlplane_ips || []).join(', ') || '-' },
    { label: 'Worker IPs', value: (cluster?.worker_ips || []).join(', ') || '-' },
    { label: 'Talos config dir', value: cluster?.talos_config_dir || '-' },
  ];

  useEffect(() => {
    const managementIp = window.location.hostname;
    if (!isIPv4(managementIp)) return undefined;

    let cancelled = false;
    const loadIpSuggestions = async () => {
      try {
        const res = await fetch(`/api/ip-suggestions?management_ip=${encodeURIComponent(managementIp)}`);
        if (!res.ok) return;
        const data = await res.json();
        if (cancelled) return;

        setForm((prev) => ({
          ...prev,
          vip_ip: prev.vip_ip === defaultForm.vip_ip ? (data.vip_ip || prev.vip_ip) : prev.vip_ip,
          start_ip: prev.start_ip === defaultForm.start_ip ? (data.start_ip || prev.start_ip) : prev.start_ip,
        }));

        if (Array.isArray(data.start_ip_block) && data.start_ip_block.length === 3) {
          setIpSuggestion(`Free range found: VIP ${data.vip_ip}, Start IP block ${data.start_ip_block.join(', ')}`);
        }
      } catch (_) {
        // Keep manual input available if auto-suggestion fails.
      }
    };

    loadIpSuggestions();
    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    if (!jobId) return;

    const poll = async () => {
      const [jobRes, logRes] = await Promise.all([
        fetch(`/api/jobs/${jobId}`),
        fetch(`/api/jobs/${jobId}/logs`),
      ]);

      if (jobRes.ok) {
        const jobData = await jobRes.json();
        setJob(jobData);
      }

      if (logRes.ok) {
        const logData = await logRes.json();
        setLogs(logData.lines || []);
      }
    };

    poll();
    const timer = setInterval(poll, 2000);
    return () => clearInterval(timer);
  }, [jobId]);

  useEffect(() => {
    if (!clusterId) return;

    const pollCluster = async () => {
      const res = await fetch(`/api/clusters/${clusterId}`);
      if (res.ok) {
        setCluster(await res.json());
      }
    };

    pollCluster();
    const timer = setInterval(pollCluster, 3000);
    return () => clearInterval(timer);
  }, [clusterId]);

  const onChange = (key, value) => {
    setForm((prev) => ({ ...prev, [key]: value }));
  };

  const startProvisioning = async () => {
    setBusy(true);
    setError('');
    setLogs([]);
    try {
      const res = await fetch('/api/clusters', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(form),
      });
      const data = await res.json();
      if (!res.ok) {
        throw new Error(data.error || 'Provisioning request failed');
      }
      setClusterId(data.cluster_id);
      setJobId(data.job_id);
    } catch (e) {
      setError(e.message);
    } finally {
      setBusy(false);
    }
  };

  const startBootstrap = async () => {
    if (!clusterId) return;
    setBusy(true);
    setError('');
    setLogs([]);
    try {
      const res = await fetch(`/api/clusters/${clusterId}/bootstrap`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          controlplane_ips: cluster?.controlplane_ips || [],
          worker_ips: cluster?.worker_ips || [],
          vip_ip: cluster?.vip_ip || form.vip_ip,
        }),
      });
      const data = await res.json();
      if (!res.ok) {
        throw new Error(data.error || 'Bootstrap request failed');
      }
      setJobId(data.job_id);
    } catch (e) {
      setError(e.message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="app-shell">
      <main className="app-main">
        <header className="hero">
          <div className="hero-copy">
            <p className="eyebrow">Twinbox Manager</p>
            <h1>Management VM Control Plane</h1>
            <p className="hero-summary">
              Provision Talos clusters, monitor execution state, and keep the active job output readable across the full
              browser width.
            </p>

            <div className="hero-callout">
              <div>
                <span className="callout-label">Current step</span>
                <p>{currentStepLabel}</p>
              </div>
              <div>
                <span className="callout-label">Latest output</span>
                <p>{latestLogLine}</p>
              </div>
            </div>
          </div>

          <div className="hero-status-strip">
            {heroMetrics.map((metric) => (
              <article key={metric.label} className="metric-card">
                <span className="metric-label">{metric.label}</span>
                <strong className="metric-value">{metric.value}</strong>
                <span className={`status-chip tone-${metric.tone}`}>{metric.chip}</span>
              </article>
            ))}
          </div>
        </header>

        <section className="dashboard-grid">
          <section className="card provision-card">
            <div className="card-header">
              <div>
                <p className="section-kicker">Provisioning</p>
                <h2>Cluster Provisioning</h2>
                <p>Submit infrastructure values for a new Talos cluster without leaving the management console.</p>
              </div>
              <span className={`status-chip tone-${canBootstrap ? 'success' : 'neutral'}`}>
                {canBootstrap ? 'Bootstrap ready' : 'Needs control planes'}
              </span>
            </div>

            <div className="form-grid">
              <label className="field">
                <span>Cluster Name</span>
                <input value={form.name} onChange={(e) => onChange('name', e.target.value)} />
              </label>
              <label className="field">
                <span>Controlplanes</span>
                <input type="number" value={form.controlplane_count} onChange={(e) => onChange('controlplane_count', Number(e.target.value))} />
              </label>
              <label className="field">
                <span>Workers</span>
                <input type="number" value={form.worker_count} onChange={(e) => onChange('worker_count', Number(e.target.value))} />
              </label>
              <label className="field">
                <span>CPU Cores</span>
                <input type="number" value={form.cpu_cores} onChange={(e) => onChange('cpu_cores', Number(e.target.value))} />
              </label>
              <label className="field">
                <span>Memory MB</span>
                <input type="number" value={form.memory_mb} onChange={(e) => onChange('memory_mb', Number(e.target.value))} />
              </label>
              <label className="field">
                <span>Disk GB</span>
                <input type="number" value={form.disk_gb} onChange={(e) => onChange('disk_gb', Number(e.target.value))} />
              </label>
              <label className="field">
                <span>Bridge</span>
                <input value={form.bridge} onChange={(e) => onChange('bridge', e.target.value)} />
              </label>
              <label className="field">
                <span>Start VMID</span>
                <input type="number" value={form.start_vmid} onChange={(e) => onChange('start_vmid', Number(e.target.value))} />
              </label>
              <label className="field">
                <span>VIP IP</span>
                <input value={form.vip_ip} onChange={(e) => onChange('vip_ip', e.target.value)} />
              </label>
              <label className="field">
                <span>Start IP</span>
                <input value={form.start_ip} onChange={(e) => onChange('start_ip', e.target.value)} />
              </label>
            </div>

            {ipSuggestion ? <p className="hint">{ipSuggestion}</p> : null}

            <div className="actions">
              <button type="button" onClick={startProvisioning} disabled={busy}>
                Start Provisioning
              </button>
              <button type="button" className="secondary-action" onClick={startBootstrap} disabled={busy || !canBootstrap}>
                Start Bootstrap
              </button>
            </div>

            {error ? <p className="error">Request failed: {error}</p> : null}
          </section>

          <section className="card status-card">
            <div className="card-header">
              <div>
                <p className="section-kicker">Runtime</p>
                <h2>Execution Status</h2>
                <p>Track the active job, cluster state, and generated addresses from a single status surface.</p>
              </div>
              <span className={`status-chip tone-${toneForState(job?.status)}`}>{jobStatusLabel}</span>
            </div>

            <div className="status-highlights">
              <article className={`status-banner tone-${toneForState(job?.status)}`}>
                <span className="banner-label">Active job</span>
                <strong>{jobId || 'No job selected'}</strong>
                <p>{currentStepLabel}</p>
              </article>

              <article className={`status-banner tone-${toneForState(cluster?.status)}`}>
                <span className="banner-label">Cluster state</span>
                <strong>{clusterStatusLabel}</strong>
                <p>{clusterId || 'Create or select a cluster to populate status.'}</p>
              </article>
            </div>

            <dl className="detail-list">
              {statusDetails.map((detail) => (
                <div key={detail.label} className="detail-row">
                  <dt>{detail.label}</dt>
                  <dd>
                    <code>{detail.value}</code>
                  </dd>
                </div>
              ))}
            </dl>
          </section>
        </section>

        <section className="card log-panel">
          <div className="card-header">
            <div>
              <p className="section-kicker">Console</p>
              <h2>Job Logs</h2>
              <p>Full-width worker output for the active run, tuned for wide terminal lines and continuous polling.</p>
            </div>
            <div className="log-meta">
              <span className={`status-chip tone-${logs.length ? 'success' : 'neutral'}`}>
                {logs.length ? `${logs.length} lines` : 'No output yet'}
              </span>
              <span className="status-chip tone-neutral">{jobId || 'No active job'}</span>
            </div>
          </div>

          <pre>{logOutput}</pre>
        </section>
      </main>
    </div>
  );
}

export default App;
