import { useDeferredValue, useEffect, useMemo, useState } from 'react';
import './App.css';
import {
  STORAGE_KEY,
  formatState,
  getMissionControlModel,
  isIPv4,
  restoreUiState,
  serializeUiState,
  toneForStatus,
} from './journey.js';

function inputValueFromStep(step, input, currentDraft) {
  if (currentDraft && Object.prototype.hasOwnProperty.call(currentDraft, input.id)) {
    return currentDraft[input.id];
  }
  if (step?.state?.inputs && Object.prototype.hasOwnProperty.call(step.state.inputs, input.id)) {
    return step.state.inputs[input.id];
  }
  if (input.default !== undefined) {
    return input.default;
  }
  return input.type === 'boolean' ? false : '';
}

function mergeDraftInputs(catalog, previousDrafts) {
  const nextDrafts = { ...previousDrafts };

  for (const category of catalog?.categories || []) {
    for (const step of category.steps || []) {
      const currentDraft = nextDrafts[step.id] || {};
      const mergedDraft = { ...currentDraft };

      for (const input of step.inputs || []) {
        if (!Object.prototype.hasOwnProperty.call(mergedDraft, input.id)) {
          mergedDraft[input.id] = inputValueFromStep(step, input, currentDraft);
        }
      }

      nextDrafts[step.id] = mergedDraft;
    }
  }

  return nextDrafts;
}

function inputTypeFor(input) {
  if (input.type === 'boolean') return 'checkbox';
  if (input.type === 'integer') return 'number';
  return 'text';
}

function normalizeInputValue(input, event) {
  if (input.type === 'boolean') {
    return event.target.checked;
  }
  if (input.type === 'integer') {
    return event.target.value === '' ? '' : Number(event.target.value);
  }
  return event.target.value;
}

function buildChecks(activeStep, steps, catalogErrors) {
  const dependencyChecks = (activeStep?.depends_on || []).map((dependencyId) => {
    const dependency = steps.find((step) => step.id === dependencyId);
    return {
      label: dependency?.title || dependencyId,
      status: dependency?.status === 'done' ? 'done' : 'locked',
      detail: dependency?.status === 'done'
        ? 'Dependency complete.'
        : 'This step stays locked until the dependency completes.',
    };
  });

  const checks = [...dependencyChecks];

  if (activeStep?.latest_job) {
    checks.push({
      label: 'Latest job',
      status: activeStep.latest_job.status === 'succeeded' ? 'done' : activeStep.latest_job.status,
      detail: activeStep.latest_job.error || `Latest worker job: ${activeStep.latest_job.id}`,
    });
  }

  if (catalogErrors.length) {
    checks.push({
      label: 'Catalog validation',
      status: 'warning',
      detail: catalogErrors.join(' | '),
    });
  }

  if (checks.length === 0) {
    checks.push({
      label: 'Ready to run',
      status: activeStep?.status || 'ready',
      detail: 'Twinbox has no additional blockers for this step.',
    });
  }

  return checks;
}

function statusLabel(status) {
  return formatState(status, 'Not started');
}

function formatRuntimeTimestamp(value) {
  if (!(value instanceof Date) || Number.isNaN(value.getTime())) {
    return 'Waiting for updates';
  }
  return value.toLocaleTimeString([], {
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  });
}

function StepFields({ activeStep, draftInputs, onChange, ipSuggestion }) {
  if (!activeStep || !(activeStep.inputs || []).length) {
    return null;
  }

  return (
    <section className="workspace-section">
      <div className="section-header">
        <div>
          <p className="section-kicker">Required input</p>
          <h3>Provide only the values this step needs</h3>
        </div>
        <span className="status-chip tone-active">Manifest-driven</span>
      </div>

      <div className="field-grid">
        {activeStep.inputs.map((input) => {
          const type = inputTypeFor(input);
          const value = inputValueFromStep(activeStep, input, draftInputs);

          if (type === 'checkbox') {
            return (
              <label key={input.id} className="field field-checkbox">
                <span>{input.label}</span>
                <input
                  type="checkbox"
                  checked={Boolean(value)}
                  onChange={(event) => onChange(input.id, normalizeInputValue(input, event))}
                />
                <small>{input.help}</small>
              </label>
            );
          }

          return (
            <label key={input.id} className="field">
              <span>{input.label}</span>
              <input
                type={type}
                value={value}
                min={input.min}
                max={input.max}
                onChange={(event) => onChange(input.id, normalizeInputValue(input, event))}
              />
              <small>{input.help}</small>
            </label>
          );
        })}
      </div>

      {ipSuggestion ? (
        <div className="callout callout-inline">
          <span className="callout-label">IP suggestion</span>
          <p>{ipSuggestion}</p>
        </div>
      ) : null}
    </section>
  );
}

function StepResults({ activeStep, cluster, artifacts }) {
  if (!activeStep) return null;

  const cards = [
    activeStep.latest_job ? {
      label: 'Worker job',
      value: activeStep.latest_job.id,
      detail: activeStep.latest_job.error || formatState(activeStep.latest_job.status, 'Pending'),
    } : null,
    cluster?.status ? {
      label: 'Cluster state',
      value: formatState(cluster.status, 'Unknown'),
      detail: cluster.id || 'Cluster record not available yet.',
    } : null,
    ...artifacts.map((artifact) => ({
      label: artifact.label,
      value: artifact.value,
      detail: activeStep.side_help,
    })),
  ].filter(Boolean);

  if (!cards.length) {
    return null;
  }

  return (
    <section className="workspace-section">
      <div className="section-header">
        <div>
          <p className="section-kicker">Result</p>
          <h3>Visible outputs for this step</h3>
        </div>
        <span className={`status-chip tone-${toneForStatus(activeStep.status)}`}>{statusLabel(activeStep.status)}</span>
      </div>

      <div className="artifact-grid">
        {cards.map((card) => (
          <article key={card.label} className="artifact-card">
            <span className="metric-label">{card.label}</span>
            <strong>{card.value}</strong>
            <p>{card.detail}</p>
          </article>
        ))}
      </div>
    </section>
  );
}

function App() {
  const [catalog, setCatalog] = useState({ categories: [], errors: [] });
  const [selectedStepId, setSelectedStepId] = useState('');
  const [draftInputs, setDraftInputs] = useState({});
  const [health, setHealth] = useState(null);
  const [cluster, setCluster] = useState(null);
  const [logs, setLogs] = useState([]);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [railOpen, setRailOpen] = useState(false);
  const [hydrated, setHydrated] = useState(false);
  const [ipSuggestion, setIpSuggestion] = useState('');
  const deferredLogs = useDeferredValue(logs);

  const mission = useMemo(
    () => getMissionControlModel({
      catalog,
      selectedStepId,
      logs: deferredLogs,
      cluster,
      health,
      error,
      busy,
    }),
    [catalog, selectedStepId, deferredLogs, cluster, health, error, busy],
  );

  const activeStep = mission.activeStep;
  const catalogErrors = catalog.errors || [];
  const activeChecks = buildChecks(activeStep, mission.steps, catalogErrors);
  const runtime = mission.activity.runtime;
  const activeClusterId = useMemo(() => {
    if (!activeStep) return '';
    if (activeStep.state?.cluster_id) return activeStep.state.cluster_id;

    for (const dependencyId of activeStep.depends_on || []) {
      const dependency = mission.steps.find((step) => step.id === dependencyId);
      if (dependency?.state?.cluster_id) {
        return dependency.state.cluster_id;
      }
    }

    return '';
  }, [activeStep, mission.steps]);

  const fetchCatalogOnce = async () => {
    const res = await fetch('/api/catalog');
    const data = await res.json();
    if (!res.ok) {
      throw new Error(data.error || 'Catalog request failed');
    }
    setCatalog(data);
    setDraftInputs((prev) => mergeDraftInputs(data, prev));

    const steps = (data.categories || []).flatMap((category) => category.steps || []);
    const selectedExists = steps.some((step) => step.id === selectedStepId);
    if (!selectedExists) {
      setSelectedStepId(steps.find((step) => step.status !== 'locked')?.id || steps[0]?.id || '');
    }
  };

  useEffect(() => {
    const restored = restoreUiState(window.localStorage.getItem(STORAGE_KEY));
    setSelectedStepId(restored.selectedStepId);
    setHydrated(true);
  }, []);

  useEffect(() => {
    let cancelled = false;

    const loadCatalog = async () => {
      try {
        const res = await fetch('/api/catalog');
        const data = await res.json();
        if (!res.ok) {
          throw new Error(data.error || 'Catalog request failed');
        }
        if (cancelled) return;

        setCatalog(data);
        setDraftInputs((prev) => mergeDraftInputs(data, prev));

        const steps = (data.categories || []).flatMap((category) => category.steps || []);
        if (!steps.some((step) => step.id === selectedStepId)) {
          setSelectedStepId(steps.find((step) => step.status !== 'locked')?.id || steps[0]?.id || '');
        }
      } catch (catalogError) {
        if (!cancelled) {
          setError(catalogError.message);
        }
      }
    };

    loadCatalog();
    const timer = setInterval(loadCatalog, 3000);
    return () => {
      cancelled = true;
      clearInterval(timer);
    };
  }, [selectedStepId]);

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
    if (!hydrated) return;
    window.localStorage.setItem(
      STORAGE_KEY,
      serializeUiState({ selectedStepId }),
    );
  }, [hydrated, selectedStepId]);

  useEffect(() => {
    if (!activeStep?.latest_job?.id) {
      setLogs([]);
      return undefined;
    }

    let cancelled = false;
    const loadLogs = async () => {
      const res = await fetch(`/api/jobs/${activeStep.latest_job.id}/logs`);
      if (!res.ok || cancelled) return;
      const data = await res.json();
      setLogs(data.lines || []);
    };

    loadLogs();
    const timer = setInterval(loadLogs, 2000);
    return () => {
      cancelled = true;
      clearInterval(timer);
    };
  }, [activeStep?.latest_job?.id]);

  useEffect(() => {
    if (!activeClusterId) {
      setCluster(null);
      return undefined;
    }

    let cancelled = false;
    const loadCluster = async () => {
      const res = await fetch(`/api/clusters/${activeClusterId}`);
      if (!res.ok || cancelled) return;
      setCluster(await res.json());
    };

    loadCluster();
    const timer = setInterval(loadCluster, 3000);
    return () => {
      cancelled = true;
      clearInterval(timer);
    };
  }, [activeClusterId]);

  const provisionDraft = draftInputs['provision-nodes'] || {};

  useEffect(() => {
    if (activeStep?.id !== 'provision-nodes') {
      setIpSuggestion('');
      return undefined;
    }

    const managementIp = window.location.hostname;
    if (!isIPv4(managementIp)) return undefined;
    const controlplaneCount = Number(provisionDraft.controlplane_count ?? activeStep.inputs.find((input) => input.id === 'controlplane_count')?.default ?? 1);
    const workerCount = Number(provisionDraft.worker_count ?? activeStep.inputs.find((input) => input.id === 'worker_count')?.default ?? 0);
    const nodeCount = controlplaneCount + workerCount;
    if (!Number.isInteger(nodeCount) || nodeCount < 1) return undefined;

    let cancelled = false;
    const loadIpSuggestions = async () => {
      try {
        const res = await fetch(`/api/ip-suggestions?management_ip=${encodeURIComponent(managementIp)}&node_count=${encodeURIComponent(nodeCount)}`);
        if (!res.ok || cancelled) return;

        const data = await res.json();
        setDraftInputs((prev) => {
          const current = prev['provision-nodes'] || {};
          const nameField = activeStep.inputs.find((input) => input.id === 'name');
          const vipField = activeStep.inputs.find((input) => input.id === 'vip_ip');
          const startField = activeStep.inputs.find((input) => input.id === 'start_ip');
          const vmidField = activeStep.inputs.find((input) => input.id === 'start_vmid');

          return {
            ...prev,
            'provision-nodes': {
              ...current,
              name: current.name === undefined || current.name === nameField?.default ? (data.name_suggestion || current.name) : current.name,
              start_vmid: current.start_vmid === undefined || current.start_vmid === vmidField?.default ? (data.start_vmid || current.start_vmid) : current.start_vmid,
              vip_ip: current.vip_ip === undefined || current.vip_ip === vipField?.default ? (data.vip_ip || current.vip_ip) : current.vip_ip,
              start_ip: current.start_ip === undefined || current.start_ip === startField?.default ? (data.start_ip || current.start_ip) : current.start_ip,
            },
          };
        });

        if (Array.isArray(data.start_ip_block) && data.start_ip_block.length === nodeCount) {
          const vmidBlock = Array.isArray(data.vmid_block) && data.vmid_block.length > 0
            ? `${data.vmid_block[0]}-${data.vmid_block[data.vmid_block.length - 1]}`
            : data.start_vmid;
          setIpSuggestion(`Free range found: VMIDs ${vmidBlock}, VIP ${data.vip_ip}, node block ${data.start_ip_block.join(', ')}`);
        }
      } catch {
        setIpSuggestion('');
      }
    };

    loadIpSuggestions();
    return () => {
      cancelled = true;
    };
  }, [activeStep, provisionDraft.controlplane_count, provisionDraft.worker_count]);

  const goToStep = (stepId) => {
    const target = mission.steps.find((step) => step.id === stepId);
    if (!target || target.status === 'locked') return;
    setSelectedStepId(stepId);
    setRailOpen(false);
  };

  const onInputChange = (inputId, value) => {
    if (!activeStep) return;
    setDraftInputs((prev) => ({
      ...prev,
      [activeStep.id]: {
        ...(prev[activeStep.id] || {}),
        [inputId]: value,
      },
    }));
  };

  const executeStep = async () => {
    if (!activeStep) return;

    setBusy(true);
    setError('');
    try {
      const res = await fetch(`/api/steps/${activeStep.id}/execute`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          inputs: draftInputs[activeStep.id] || {},
        }),
      });
      const data = await res.json();
      if (!res.ok) {
        throw new Error(data.error || 'Step execution failed');
      }

      await fetchCatalogOnce();
    } catch (requestError) {
      setError(requestError.message);
    } finally {
      setBusy(false);
    }
  };

  const handlePrimaryAction = async () => {
    if (mission.primaryAction.type === 'advance' && mission.nextStep) {
      goToStep(mission.nextStep.id);
      return;
    }

    if (mission.primaryAction.type === 'execute') {
      await executeStep();
    }
  };

  if (!activeStep || !mission.activeCategory) {
    return (
      <div className="app-shell">
        <main className="app-main">
          <header className="global-header">
            <div className="global-header-copy">
              <p className="eyebrow">Twinbox Mission Control</p>
              <h1>Manifest-driven platform steps for the Management VM</h1>
              <p className="hero-summary">Loading the step catalog from the backend.</p>
            </div>
          </header>
        </main>
      </div>
    );
  }

  return (
    <div className="app-shell">
      <main className="app-main">
        <header className="global-header">
          <div className="global-header-copy">
            <p className="eyebrow">Twinbox Mission Control</p>
            <h1>Manifest-driven platform steps for the Management VM</h1>
            <p className="hero-summary">
              Twinbox discovers project-owned categories and steps from the backend catalog, shows the exact inputs and explanations
              for each step, and keeps execution logs and artifacts visible while the worker runs.
            </p>
          </div>

          <div className="global-header-stats">
            <article className="header-stat">
              <span className="metric-label">Category</span>
              <strong>{mission.activeCategory.title}</strong>
              <span className={`status-chip tone-${toneForStatus(mission.activeCategory.status)}`}>{statusLabel(mission.activeCategory.status)}</span>
            </article>
            <article className="header-stat">
              <span className="metric-label">Category progress</span>
              <strong>{`${mission.progress.categoryIndex} / ${mission.progress.categoryCount}`}</strong>
              <span className="status-chip tone-neutral">{mission.activeCategory.title}</span>
            </article>
            <article className="header-stat">
              <span className="metric-label">Step</span>
              <strong>{`${mission.progress.stepIndex} / ${mission.progress.totalSteps}`}</strong>
              <span className={`status-chip tone-${toneForStatus(activeStep.status)}`}>{statusLabel(activeStep.status)}</span>
            </article>
            <article className="header-stat">
              <span className="metric-label">Progress</span>
              <strong>{`${mission.progress.percent}% complete`}</strong>
              <span className="status-chip tone-active">{`${mission.progress.completedSteps}/${mission.progress.totalSteps} done`}</span>
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
          {railOpen ? 'Close catalog overview' : 'Open catalog overview'}
        </button>

        <section className="mission-grid">
          <aside className="journey-rail" data-mobile-open={railOpen}>
            <div className="rail-header">
              <div>
                <p className="section-kicker">Catalog</p>
                <h2>Management VM steps</h2>
              </div>
              <span className="status-chip tone-neutral">{`${mission.progress.completedSteps}/${mission.progress.totalSteps} steps done`}</span>
            </div>

            <div className="phase-list">
              {mission.categories.map((category, index) => (
                <button
                  key={category.id}
                  type="button"
                  className={`phase-card ${category.id === mission.activeCategory.id ? 'is-active' : ''}`}
                  onClick={() => {
                    const targetStep = category.steps.find((step) => step.status !== 'locked') || category.steps[0];
                    if (targetStep) {
                      goToStep(targetStep.id);
                    }
                  }}
                >
                  <div className="phase-card-top">
                    <span className="phase-index">{`Category ${index + 1}`}</span>
                    <span className={`status-chip tone-${toneForStatus(category.status)}`}>{statusLabel(category.status)}</span>
                  </div>
                  <strong>{category.title}</strong>
                  <p>{category.blocker}</p>
                  <div className="phase-progress">
                    <span style={{ width: `${category.percent}%` }} />
                  </div>
                  <small>{`${category.completedSteps}/${category.totalSteps} steps done`}</small>
                </button>
              ))}
            </div>
          </aside>

          <section className="workspace-panel">
            <div className="workspace-header">
              <div>
                <p className="section-kicker">{mission.activeCategory.title}</p>
                <h2>{activeStep.title}</h2>
                <p>{mission.activity.summary}</p>
              </div>
              <span className={`status-chip tone-${toneForStatus(activeStep.status)}`}>{statusLabel(activeStep.status)}</span>
            </div>

            <div className="workspace-meta">
              <article className="meta-card">
                <span className="metric-label">What this step does</span>
                <strong>{activeStep.type === 'config' ? 'Configuration' : 'Execution'}</strong>
                <p>{activeStep.explanation}</p>
              </article>
              <article className="meta-card">
                <span className="metric-label">Operator guidance</span>
                <strong>{activeStep.title}</strong>
                <p>{activeStep.side_help}</p>
              </article>
            </div>

            <section className="workspace-section">
              <div className="runtime-strip">
                <div className="section-header">
                  <div>
                    <p className="section-kicker">Live runtime</p>
                    <h3>Current stage</h3>
                  </div>
                  <div className="runtime-strip-meta">
                    {runtime.isLive ? <span className="runtime-pulse" aria-hidden="true" /> : null}
                    <span className={`status-chip tone-${toneForStatus(runtime.runState)}`}>{statusLabel(runtime.runState)}</span>
                  </div>
                </div>

                <div className="runtime-summary-grid">
                  <article className="runtime-summary-card">
                    <span className="metric-label">Current stage</span>
                    <strong>{runtime.currentStage}</strong>
                    <p>{runtime.isStale ? 'No new activity recently. Twinbox is still polling.' : 'Twinbox is translating worker activity into a step-by-step timeline.'}</p>
                  </article>
                  <article className="runtime-summary-card">
                    <span className="metric-label">Updated</span>
                    <strong>{runtime.lastUpdatedLabel}</strong>
                    <p>{runtime.isLive ? 'Polling is active while the current job is running.' : 'Twinbox will refresh this timeline when the next job starts.'}</p>
                  </article>
                  <article className="runtime-summary-card">
                    <span className="metric-label">Timeline</span>
                    <strong>{`${runtime.eventCount} events`}</strong>
                    <p>{runtime.timelineEvents.at(-1)?.detail || 'Run the selected step to generate visible progress events.'}</p>
                  </article>
                </div>

                <div className="timeline-list">
                  {runtime.timelineEvents.map((event) => (
                    <article key={event.id} className={`timeline-card tone-${event.tone}`}>
                      <div className="timeline-card-top">
                        <strong>{event.title}</strong>
                        <span className="status-chip tone-neutral">{formatRuntimeTimestamp(event.timestamp)}</span>
                      </div>
                      <p>{event.detail}</p>
                    </article>
                  ))}
                </div>
              </div>
            </section>

            <section className="workspace-section">
              <div className="section-header">
                <div>
                  <p className="section-kicker">Checks</p>
                  <h3>What Twinbox verifies before or during this step</h3>
                </div>
                <span className="status-chip tone-neutral">{`${activeChecks.length} checks`}</span>
              </div>

              <div className="check-list">
                {activeChecks.map((check) => (
                  <article key={`${check.label}-${check.detail}`} className={`check-card tone-${toneForStatus(check.status)}`}>
                    <div className="check-card-top">
                      <strong>{check.label}</strong>
                      <span className={`status-chip tone-${toneForStatus(check.status)}`}>{statusLabel(check.status)}</span>
                    </div>
                    <p>{check.detail}</p>
                  </article>
                ))}
              </div>
            </section>

            <StepFields
              activeStep={activeStep}
              draftInputs={draftInputs[activeStep.id] || {}}
              onChange={onInputChange}
              ipSuggestion={ipSuggestion}
            />
            <StepResults
              activeStep={activeStep}
              cluster={cluster}
              artifacts={mission.activity.artifacts}
            />

            {error ? (
              <div className="callout callout-danger">
                <span className="callout-label">Latest error</span>
                <p>{error}</p>
              </div>
            ) : null}

            {catalogErrors.length ? (
              <div className="callout callout-inline">
                <span className="callout-label">Catalog warnings</span>
                <p>{catalogErrors.join(' | ')}</p>
              </div>
            ) : null}

            <div className="bottom-actions">
              <button
                type="button"
                className="secondary-action"
                onClick={() => mission.previousStep && goToStep(mission.previousStep.id)}
                disabled={!mission.previousStep}
              >
                Previous
              </button>
              <button type="button" className="ghost-action" onClick={fetchCatalogOnce}>
                Refresh catalog
              </button>
              <button
                type="button"
                aria-label={mission.primaryAction.label}
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
                  <p className="section-kicker">Now active</p>
                  <h3>Step context</h3>
                </div>
                <span className={`status-chip tone-${toneForStatus(activeStep.status)}`}>{statusLabel(activeStep.status)}</span>
              </div>
              <p className="panel-summary">{mission.activity.summary}</p>
            </section>

            <section className="panel-card">
              <div className="section-header">
                <div>
                  <p className="section-kicker">Live summary</p>
                  <h3>Runtime snapshot</h3>
                </div>
                <span className={`status-chip tone-${toneForStatus(runtime.runState)}`}>{statusLabel(runtime.runState)}</span>
              </div>
              <div className="event-list">
                <article className={`event-card tone-${toneForStatus(runtime.runState)}`}>
                  <strong>{runtime.currentStage}</strong>
                  <p>{runtime.lastUpdatedLabel}</p>
                </article>
                <article className="event-card tone-neutral">
                  <strong>Most recent event</strong>
                  <p>{runtime.timelineEvents.at(-1)?.detail || 'No worker output yet.'}</p>
                </article>
              </div>
            </section>

            <section className="panel-card">
              <div className="section-header">
                <div>
                  <p className="section-kicker">Artifacts</p>
                  <h3>Saved and discovered state</h3>
                </div>
                <span className="status-chip tone-neutral">{`${mission.activity.artifacts.length} items`}</span>
              </div>
              <dl className="artifact-list">
                {mission.activity.artifacts.length ? (
                  mission.activity.artifacts.map((artifact) => (
                    <div key={`${artifact.label}-${artifact.value}`} className="artifact-row">
                      <dt>{artifact.label}</dt>
                      <dd>{artifact.value}</dd>
                    </div>
                  ))
                ) : (
                  <div className="artifact-row">
                    <dt>No artifacts yet</dt>
                    <dd>Run the selected step to generate visible outputs.</dd>
                  </div>
                )}
              </dl>
            </section>

            <section className="panel-card">
              <div className="section-header">
                <div>
                  <p className="section-kicker">Risks / notes</p>
                  <h3>Operator context</h3>
                </div>
                <span className="status-chip tone-warning">{mission.activity.risks.length} notes</span>
              </div>
              <div className="risk-list">
                {mission.activity.risks.map((risk) => (
                  <article key={`${risk.label}-${risk.detail}`} className={`risk-card tone-${risk.tone || 'neutral'}`}>
                    <strong>{risk.label}</strong>
                    <p>{risk.detail}</p>
                  </article>
                ))}
              </div>
            </section>

            <details className="technical-panel">
              <summary>Technical details</summary>
              <pre>{mission.activity.rawLogOutput}</pre>
            </details>
          </aside>
        </section>
      </main>
    </div>
  );
}

export default App;
