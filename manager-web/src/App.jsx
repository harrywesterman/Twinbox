import { useDeferredValue, useEffect, useMemo, useState } from 'react';
import './App.css';
import {
  STORAGE_KEY,
  defaultForm,
  formatState,
  getMissionControlModel,
  isIPv4,
  restoreMissionState,
  serializeMissionState,
  toneForStatus,
} from './journey.js';

const fieldMeta = {
  name: {
    label: 'Cluster name',
    type: 'text',
    help: 'Readable Twinbox cluster name.',
  },
  controlplane_count: {
    label: 'Control planes',
    type: 'number',
    help: 'Current API range: 1-15.',
  },
  worker_count: {
    label: 'Workers',
    type: 'number',
    help: 'Current API range: 0-200.',
  },
  cpu_cores: {
    label: 'CPU cores',
    type: 'number',
    help: 'Per-node CPU request.',
  },
  memory_mb: {
    label: 'Memory MB',
    type: 'number',
    help: 'Per-node memory allocation.',
  },
  disk_gb: {
    label: 'Disk GB',
    type: 'number',
    help: 'System disk size per VM.',
  },
  bridge: {
    label: 'Bridge',
    type: 'text',
    help: 'Proxmox bridge for Talos node traffic.',
  },
  start_vmid: {
    label: 'Start VMID',
    type: 'number',
    help: 'Seed VMID for the cluster inventory.',
  },
  vip_ip: {
    label: 'VIP IP',
    type: 'text',
    help: 'Virtual IP for the Talos control plane.',
  },
  start_ip: {
    label: 'Start IP',
    type: 'text',
    help: 'First node address in the reserved block.',
  },
};

function statusLabel(status) {
  return formatState(status, 'Not started');
}

function StepFields({ activeStep, form, onChange, ipSuggestion }) {
  if (activeStep.kind !== 'input') {
    return null;
  }

  return (
    <section className="workspace-section">
      <div className="section-header">
        <div>
          <p className="section-kicker">Benodigde invoer</p>
          <h3>Vul alleen de gegevens in die deze stap nodig heeft</h3>
        </div>
        <span className="status-chip tone-active">Just-in-time</span>
      </div>

      <div className="field-grid">
        {activeStep.fields.map((field) => {
          const meta = fieldMeta[field];
          return (
            <label key={field} className="field">
              <span>{meta.label}</span>
              <input
                type={meta.type}
                value={form[field]}
                onChange={(event) => {
                  const value = meta.type === 'number' ? Number(event.target.value) : event.target.value;
                  onChange(field, value);
                }}
              />
              <small>{meta.help}</small>
            </label>
          );
        })}
      </div>

      {activeStep.id === 'foundation-network-plan' ? (
        <div className="callout callout-inline">
          <span className="callout-label">IP suggestion</span>
          <p>{ipSuggestion || 'Geen automatische range gevonden; handmatige invoer blijft beschikbaar.'}</p>
        </div>
      ) : null}
    </section>
  );
}

function StepResults({ activeStep, cluster, job }) {
  if (activeStep.id === 'talos-provision') {
    return (
      <section className="workspace-section">
        <div className="section-header">
          <div>
            <p className="section-kicker">Uitvoering</p>
            <h3>Provisioning runtime</h3>
          </div>
          <span className={`status-chip tone-${toneForStatus(activeStep.status)}`}>{statusLabel(activeStep.status)}</span>
        </div>

        <div className="result-grid">
          <article className="result-card">
            <span className="metric-label">Cluster</span>
            <strong>{cluster?.id || 'Nog geen cluster-ID'}</strong>
            <p>{cluster?.status ? `Cluster state: ${formatState(cluster.status, 'Requested')}` : 'Twinbox maakt na submission een clusterrecord aan.'}</p>
          </article>
          <article className="result-card">
            <span className="metric-label">Worker job</span>
            <strong>{job?.id || 'Nog geen job-ID'}</strong>
            <p>{job?.step ? `Laatste worker stap: ${formatState(job.step, 'Queued')}` : 'De create_cluster job verschijnt hier zodra hij gequeued is.'}</p>
          </article>
        </div>
      </section>
    );
  }

  if (activeStep.id === 'talos-bootstrap' || activeStep.id === 'talos-validate') {
    return (
      <section className="workspace-section">
        <div className="section-header">
          <div>
            <p className="section-kicker">Resultaat</p>
            <h3>Controleer de aangemaakte cluster-artifacts</h3>
          </div>
          <span className={`status-chip tone-${toneForStatus(activeStep.status)}`}>{statusLabel(activeStep.status)}</span>
        </div>

        <div className="artifact-grid">
          <article className="artifact-card">
            <span className="metric-label">Control planes</span>
            <strong>{(cluster?.controlplane_ips || []).join(', ') || 'Nog niet beschikbaar'}</strong>
            <p>Twinbox toont hier de control-plane adressen waarmee de bootstrap-flow werkt.</p>
          </article>
          <article className="artifact-card">
            <span className="metric-label">Workers</span>
            <strong>{(cluster?.worker_ips || []).join(', ') || 'Nog niet beschikbaar'}</strong>
            <p>De worker-inventory blijft zichtbaar zodat latere fases niet blind op verborgen state leunen.</p>
          </article>
          <article className="artifact-card">
            <span className="metric-label">Talos config</span>
            <strong>{cluster?.talos_config_dir || 'Nog niet beschikbaar'}</strong>
            <p>De gegenereerde Talos configuratie blijft op de Management VM beschikbaar voor vervolgfasen.</p>
          </article>
        </div>
      </section>
    );
  }

  return null;
}

function App() {
  const [form, setForm] = useState(defaultForm);
  const [completedStepIds, setCompletedStepIds] = useState([]);
  const [selectedStepId, setSelectedStepId] = useState('foundation-overview');
  const [clusterId, setClusterId] = useState('');
  const [jobId, setJobId] = useState('');
  const [cluster, setCluster] = useState(null);
  const [job, setJob] = useState(null);
  const [logs, setLogs] = useState([]);
  const [health, setHealth] = useState(null);
  const [ipSuggestion, setIpSuggestion] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [saveMessage, setSaveMessage] = useState('');
  const [railOpen, setRailOpen] = useState(false);
  const [hydrated, setHydrated] = useState(false);
  const deferredLogs = useDeferredValue(logs);

  useEffect(() => {
    const restored = restoreMissionState(window.localStorage.getItem(STORAGE_KEY));
    setForm(restored.form);
    setCompletedStepIds(restored.completedStepIds);
    setSelectedStepId(restored.selectedStepId);
    setClusterId(restored.clusterId);
    setJobId(restored.jobId);
    setHydrated(true);
  }, []);

  useEffect(() => {
    const pollHealth = async () => {
      try {
        const res = await fetch('/api/health');
        if (!res.ok) {
          throw new Error('manager API did not answer');
        }
        setHealth(await res.json());
      } catch (healthError) {
        setHealth({ ok: false, error: healthError.message });
      }
    };

    pollHealth();
    const timer = setInterval(pollHealth, 15000);
    return () => clearInterval(timer);
  }, []);

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
          setIpSuggestion(`Vrije range gevonden: VIP ${data.vip_ip}, nodeblok ${data.start_ip_block.join(', ')}`);
        }
      } catch (_) {
        setIpSuggestion('');
      }
    };

    loadIpSuggestions();
    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    if (!jobId) return undefined;

    const pollJob = async () => {
      const [jobRes, logRes] = await Promise.all([fetch(`/api/jobs/${jobId}`), fetch(`/api/jobs/${jobId}/logs`)]);

      if (jobRes.ok) {
        setJob(await jobRes.json());
      }

      if (logRes.ok) {
        const logData = await logRes.json();
        setLogs(logData.lines || []);
      }
    };

    pollJob();
    const timer = setInterval(pollJob, 2000);
    return () => clearInterval(timer);
  }, [jobId]);

  useEffect(() => {
    if (!clusterId) return undefined;

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

  useEffect(() => {
    if (!hydrated) return;

    window.localStorage.setItem(
      STORAGE_KEY,
      serializeMissionState({
        form,
        completedStepIds,
        selectedStepId,
        clusterId,
        jobId,
      }),
    );
  }, [hydrated, form, completedStepIds, selectedStepId, clusterId, jobId]);

  useEffect(() => {
    if (!saveMessage) return undefined;
    const timer = setTimeout(() => setSaveMessage(''), 3000);
    return () => clearTimeout(timer);
  }, [saveMessage]);

  const mission = useMemo(
    () =>
      getMissionControlModel({
        form,
        completedStepIds,
        cluster,
        job,
        logs: deferredLogs,
        health,
        ipSuggestion,
        error,
        busy,
        selectedStepId,
      }),
    [form, completedStepIds, cluster, job, deferredLogs, health, ipSuggestion, error, busy, selectedStepId],
  );

  const activeStep = mission.activeStep;
  const activeChecks = activeStep.checks || [];

  const onChange = (key, value) => {
    setForm((prev) => ({ ...prev, [key]: value }));
  };

  const goToStep = (stepId) => {
    const target = mission.steps.find((step) => step.id === stepId);
    if (!target || target.status === 'locked') return;
    setSelectedStepId(stepId);
    setRailOpen(false);
  };

  const markStepComplete = (stepId) => {
    setCompletedStepIds((prev) => (prev.includes(stepId) ? prev : [...prev, stepId]));
  };

  const advanceToNextStep = () => {
    if (!mission.nextStep || mission.nextStep.status === 'locked') return;
    if (activeStep.kind !== 'action' && activeStep.status !== 'done') {
      markStepComplete(activeStep.id);
    }
    setSelectedStepId(mission.nextStep.id);
  };

  const saveProgress = () => {
    window.localStorage.setItem(
      STORAGE_KEY,
      serializeMissionState({
        form,
        completedStepIds,
        selectedStepId,
        clusterId,
        jobId,
      }),
    );
    setSaveMessage(`Voortgang opgeslagen op ${new Date().toLocaleTimeString('nl-NL', { hour: '2-digit', minute: '2-digit' })}`);
  };

  const startProvisioning = async () => {
    setBusy(true);
    setError('');
    setLogs([]);
    setJob({
      id: '',
      type: 'create_cluster',
      status: 'pending',
      step: 'queued',
    });

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
      setJob({
        id: data.job_id,
        type: 'create_cluster',
        status: 'pending',
        step: 'queued',
      });
    } catch (requestError) {
      setError(requestError.message);
      setJob({
        id: '',
        type: 'create_cluster',
        status: 'failed',
        step: 'failed',
        error: requestError.message,
      });
    } finally {
      setBusy(false);
    }
  };

  const startBootstrap = async () => {
    if (!clusterId) return;

    setBusy(true);
    setError('');
    setLogs([]);
    setJob({
      id: '',
      type: 'bootstrap_cluster',
      status: 'pending',
      step: 'queued',
    });

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
      setJob({
        id: data.job_id,
        type: 'bootstrap_cluster',
        status: 'pending',
        step: 'queued',
      });
    } catch (requestError) {
      setError(requestError.message);
      setJob({
        id: '',
        type: 'bootstrap_cluster',
        status: 'failed',
        step: 'failed',
        error: requestError.message,
      });
    } finally {
      setBusy(false);
    }
  };

  const handlePrimaryAction = async () => {
    switch (mission.primaryAction.type) {
      case 'advance':
        advanceToNextStep();
        break;
      case 'provision':
      case 'retry-provision':
        await startProvisioning();
        break;
      case 'bootstrap':
      case 'retry-bootstrap':
        await startBootstrap();
        break;
      default:
        break;
    }
  };

  return (
    <div className="app-shell">
      <main className="app-main">
        <header className="global-header">
          <div className="global-header-copy">
            <p className="eyebrow">Twinbox Mission Control</p>
            <h1>Guided platform bootstrap for the Management VM</h1>
            <p className="hero-summary">
              Doorloop de volledige platformreis in vaste volgorde. Je ziet steeds wat Twinbox doet, welke artifacts al bestaan,
              en waarom de volgende stap wel of niet wordt vrijgegeven.
            </p>
          </div>

          <div className="global-header-stats">
            <article className="header-stat">
              <span className="metric-label">Omgeving</span>
              <strong>{form.name}</strong>
              <span className="status-chip tone-neutral">{clusterId || 'Nog geen cluster-ID'}</span>
            </article>
            <article className="header-stat">
              <span className="metric-label">Fase</span>
              <strong>{`${mission.progress.phaseIndex} / ${mission.progress.phaseCount}`}</strong>
              <span className={`status-chip tone-${toneForStatus(mission.activePhase.status)}`}>{mission.activePhase.title}</span>
            </article>
            <article className="header-stat">
              <span className="metric-label">Stap</span>
              <strong>{`${mission.progress.stepIndex} / ${mission.progress.totalSteps}`}</strong>
              <span className={`status-chip tone-${toneForStatus(activeStep.status)}`}>{statusLabel(activeStep.status)}</span>
            </article>
            <article className="header-stat">
              <span className="metric-label">Voortgang</span>
              <strong>{`${mission.progress.percent}% complete`}</strong>
              <span className="status-chip tone-active">{mission.progress.remainingEtaLabel}</span>
            </article>
          </div>

          <div className="health-strip">
            {mission.healthBadges.map((badge) => (
              <article key={badge.id} className="health-card">
                <span className="metric-label">{badge.label}</span>
                <strong>{badge.value}</strong>
                <span className={`status-chip tone-${badge.tone}`}>{badge.chip}</span>
              </article>
            ))}
          </div>
        </header>

        <button
          type="button"
          className="journey-rail-toggle"
          onClick={() => setRailOpen((open) => !open)}
        >
          {railOpen ? 'Sluit reisoverzicht' : 'Open reisoverzicht'}
        </button>

        <section className="mission-grid">
          <aside className="journey-rail" data-mobile-open={railOpen}>
            <div className="rail-header">
              <div>
                <p className="section-kicker">Installatiereis</p>
                <h2>Platform bootstrap</h2>
              </div>
              <span className="status-chip tone-neutral">{`${mission.progress.completedSteps}/${mission.progress.totalSteps} stappen gereed`}</span>
            </div>

            <div className="phase-list">
              {mission.phases.map((phase, index) => (
                <button
                  key={phase.id}
                  type="button"
                  className={`phase-card ${phase.id === mission.activePhase.id ? 'is-active' : ''}`}
                  onClick={() => {
                    const firstOpenStep = phase.steps.find((step) => step.status !== 'locked');
                    if (firstOpenStep) {
                      goToStep(firstOpenStep.id);
                    }
                  }}
                  disabled={!phase.steps.some((step) => step.status !== 'locked')}
                >
                  <div className="phase-card-top">
                    <span className="phase-index">{`Fase ${index + 1}`}</span>
                    <span className={`status-chip tone-${toneForStatus(phase.status)}`}>{statusLabel(phase.status)}</span>
                  </div>
                  <strong>{phase.title}</strong>
                  <p>{phase.blocker}</p>
                  <div className="phase-progress">
                    <span style={{ width: `${phase.percent}%` }} />
                  </div>
                  <small>{`${phase.completedSteps}/${phase.totalSteps} substappen gereed`}</small>
                </button>
              ))}
            </div>
          </aside>

          <section className="workspace-panel">
            <div className="workspace-header">
              <div>
                <p className="section-kicker">{mission.activePhase.title}</p>
                <h2>{activeStep.title}</h2>
                <p>{mission.activity.summary}</p>
              </div>
              <span className={`status-chip tone-${toneForStatus(activeStep.status)}`}>{statusLabel(activeStep.status)}</span>
            </div>

            <div className="workspace-meta">
              <article className="meta-card">
                <span className="metric-label">Waarom deze stap bestaat</span>
                <strong>{activeStep.shortTitle}</strong>
                <p>{activeStep.why}</p>
              </article>
              <article className="meta-card">
                <span className="metric-label">Installatie-impact</span>
                <strong>{activeStep.kind === 'action' ? 'Wijzigt platformstate' : 'Beheerst beslismoment'}</strong>
                <p>{activeStep.risk}</p>
              </article>
            </div>

            <section className="workspace-section">
              <div className="section-header">
                <div>
                  <p className="section-kicker">Pre-flight checks</p>
                  <h3>Wat Twinbox controleert voor deze stap</h3>
                </div>
                <span className="status-chip tone-neutral">{`${activeChecks.length} checks`}</span>
              </div>

              <div className="check-list">
                {activeChecks.map((check) => (
                  <article key={check.label} className={`check-card tone-${toneForStatus(check.status)}`}>
                    <div className="check-card-top">
                      <strong>{check.label}</strong>
                      <span className={`status-chip tone-${toneForStatus(check.status)}`}>{statusLabel(check.status)}</span>
                    </div>
                    <p>{check.detail}</p>
                  </article>
                ))}
              </div>
            </section>

            <StepFields activeStep={activeStep} form={form} onChange={onChange} ipSuggestion={ipSuggestion} />
            <StepResults activeStep={activeStep} cluster={cluster} job={job} />

            {error ? (
              <div className="callout callout-danger">
                <span className="callout-label">Laatste fout</span>
                <p>{error}</p>
              </div>
            ) : null}

            {saveMessage ? (
              <div className="callout callout-inline">
                <span className="callout-label">Opslaan en hervatten</span>
                <p>{saveMessage}</p>
              </div>
            ) : null}

            <div className="bottom-actions">
              <button
                type="button"
                className="secondary-action"
                onClick={() => mission.previousStep && goToStep(mission.previousStep.id)}
                disabled={!mission.previousStep}
              >
                Vorige
              </button>
              <button type="button" className="ghost-action" onClick={saveProgress}>
                Opslaan en later verder
              </button>
              <button
                type="button"
                aria-label={mission.primaryAction.type === 'advance' ? 'Volgende' : mission.primaryAction.label}
                onClick={handlePrimaryAction}
                disabled={mission.primaryAction.disabled}
              >
                {mission.primaryAction.label}
              </button>
            </div>

            {mission.primaryAction.helperText ? <p className="action-helper">{mission.primaryAction.helperText}</p> : null}
          </section>

          <aside className="activity-panel">
            <section className="panel-card">
              <div className="section-header">
                <div>
                  <p className="section-kicker">Nu bezig</p>
                  <h3>Actieve missiecontext</h3>
                </div>
                <span className={`status-chip tone-${toneForStatus(activeStep.status)}`}>{statusLabel(activeStep.status)}</span>
              </div>
              <p className="panel-summary">{mission.activity.summary}</p>
            </section>

            <section className="panel-card">
              <div className="section-header">
                <div>
                  <p className="section-kicker">Live events</p>
                  <h3>Mensentaal eerst</h3>
                </div>
                <span className="status-chip tone-neutral">{`${mission.activity.events.length} events`}</span>
              </div>
              <div className="event-list">
                {mission.activity.events.map((event) => (
                  <article key={event.id} className={`event-card tone-${event.tone}`}>
                    <strong>{event.title}</strong>
                    <p>{event.detail}</p>
                  </article>
                ))}
              </div>
            </section>

            <section className="panel-card">
              <div className="section-header">
                <div>
                  <p className="section-kicker">Aangemaakt / gewijzigd</p>
                  <h3>Artifacts</h3>
                </div>
                <span className="status-chip tone-neutral">{`${mission.activity.artifacts.length} items`}</span>
              </div>
              <dl className="artifact-list">
                {mission.activity.artifacts.length ? (
                  mission.activity.artifacts.map((artifact) => (
                    <div key={artifact.label} className="artifact-row">
                      <dt>{artifact.label}</dt>
                      <dd>{artifact.value}</dd>
                    </div>
                  ))
                ) : (
                  <div className="artifact-row">
                    <dt>Nog leeg</dt>
                    <dd>Artifacts verschijnen zodra Twinbox platformstate aanmaakt.</dd>
                  </div>
                )}
              </dl>
            </section>

            <section className="panel-card">
              <div className="section-header">
                <div>
                  <p className="section-kicker">Risico's / aandacht</p>
                  <h3>Operator context</h3>
                </div>
                <span className="status-chip tone-warning">{mission.activity.risks.length || 1} notes</span>
              </div>
              <div className="risk-list">
                {(mission.activity.risks.length ? mission.activity.risks : [{ label: 'Geen extra waarschuwingen', detail: 'Twinbox heeft op dit moment geen aanvullende risico-signalen voor deze stap.' }]).map((risk) => (
                  <article key={risk.label} className={`risk-card tone-${risk.tone || 'neutral'}`}>
                    <strong>{risk.label}</strong>
                    <p>{risk.detail}</p>
                  </article>
                ))}
              </div>
            </section>

            <details className="technical-panel">
              <summary>Technische details</summary>
              <pre>{mission.activity.rawLogOutput}</pre>
            </details>
          </aside>
        </section>
      </main>
    </div>
  );
}

export default App;
