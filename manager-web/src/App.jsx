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

function App() {
  const [form, setForm] = useState(defaultForm);
  const [clusterId, setClusterId] = useState('');
  const [jobId, setJobId] = useState('');
  const [job, setJob] = useState(null);
  const [logs, setLogs] = useState([]);
  const [cluster, setCluster] = useState(null);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  const canBootstrap = useMemo(() => {
    if (!cluster) return false;
    return Array.isArray(cluster.controlplane_ips) && cluster.controlplane_ips.length > 0;
  }, [cluster]);

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
    <div className="layout">
      <header className="header">
        <h1>Twinbox Manager</h1>
        <p>LAN-only control plane for Talos provisioning and bootstrap</p>
      </header>

      <main className="content">
        <section className="card">
          <h2>Cluster Provisioning</h2>
          <div className="grid">
            <label>Cluster Name<input value={form.name} onChange={(e) => onChange('name', e.target.value)} /></label>
            <label>Controlplanes<input type="number" value={form.controlplane_count} onChange={(e) => onChange('controlplane_count', Number(e.target.value))} /></label>
            <label>Workers<input type="number" value={form.worker_count} onChange={(e) => onChange('worker_count', Number(e.target.value))} /></label>
            <label>CPU Cores<input type="number" value={form.cpu_cores} onChange={(e) => onChange('cpu_cores', Number(e.target.value))} /></label>
            <label>Memory MB<input type="number" value={form.memory_mb} onChange={(e) => onChange('memory_mb', Number(e.target.value))} /></label>
            <label>Disk GB<input type="number" value={form.disk_gb} onChange={(e) => onChange('disk_gb', Number(e.target.value))} /></label>
            <label>Bridge<input value={form.bridge} onChange={(e) => onChange('bridge', e.target.value)} /></label>
            <label>Start VMID<input type="number" value={form.start_vmid} onChange={(e) => onChange('start_vmid', Number(e.target.value))} /></label>
            <label>VIP IP<input value={form.vip_ip} onChange={(e) => onChange('vip_ip', e.target.value)} /></label>
            <label>Start IP<input value={form.start_ip} onChange={(e) => onChange('start_ip', e.target.value)} /></label>
          </div>
          <div className="row">
            <button onClick={startProvisioning} disabled={busy}>Start Provisioning</button>
            <button onClick={startBootstrap} disabled={busy || !canBootstrap}>Start Bootstrap</button>
          </div>
          {error ? <p className="error">{error}</p> : null}
        </section>

        <section className="card">
          <h2>Execution Status</h2>
          <p>Cluster ID: <code>{clusterId || '-'}</code></p>
          <p>Job ID: <code>{jobId || '-'}</code></p>
          <p>Status: <strong>{job?.status || '-'}</strong></p>
          <p>Step: <strong>{job?.step || '-'}</strong></p>
          <p>Result: <strong>{cluster?.status || '-'}</strong></p>
          <p>Controlplane IPs: <code>{(cluster?.controlplane_ips || []).join(', ') || '-'}</code></p>
          <p>Worker IPs: <code>{(cluster?.worker_ips || []).join(', ') || '-'}</code></p>
          <p>Talos config dir: <code>{cluster?.talos_config_dir || '-'}</code></p>
        </section>

        <section className="card logs">
          <h2>Job Logs</h2>
          <pre>{logs.length ? logs.map((l) => l.line).join('\n') : 'No logs yet.'}</pre>
        </section>
      </main>
    </div>
  );
}

export default App;
