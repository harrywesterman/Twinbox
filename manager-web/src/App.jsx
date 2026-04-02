import { useEffect, useMemo, useRef, useState } from 'react';

import './App.css';
import {
  buildProvisionPlacementBoard,
  PROVISION_AUTOSCALED_FIELDS,
  buildProvisionScaleSummary,
  buildScaledProvisionInputs,
  getProvisionNodeCount,
  formatMemoryMb,
} from './provision-scale.js';
import {
  buildProvisionVmIpMap,
  buildProvisionVmIpRows,
  validateProvisionVmIpRows,
} from './provision-network.js';
import {
  buildSuggestedProvisionInputs,
  mergeSuggestedProvisionDraft,
} from './provision-defaults.js';
import {
  buildWizardExportFilename,
  getMissionControlModel,
  getWizardSteps,
  restoreUiState,
  serializeUiState,
  STORAGE_KEY,
  formatState,
} from './journey.js';
import {
  isMissingClusterError,
  isProvisionSuggestionReady,
  recoverMissingClusterState,
  recoverRecreatedClusterState,
  shouldResetRecreatedClusterDraft,
  refreshWizardSnapshot,
} from './catalog-refresh.js';

const POLL_INTERVAL_MS = 5000;

function sleep(ms) {
  return new Promise((resolve) => {
    window.setTimeout(resolve, ms);
  });
}

async function requestJson(url, options = {}) {
  const response = await fetch(url, {
    headers: {
      'Content-Type': 'application/json',
      ...(options.headers || {}),
    },
    ...options,
  });

  const text = await response.text();
  let body = null;

  if (text) {
    try {
      body = JSON.parse(text);
    } catch {
      body = text;
    }
  }

  if (!response.ok) {
    const error = new Error(body?.error || body?.message || text || `Request failed with ${response.status}`);
    error.status = response.status;
    error.body = body;
    error.url = url;
    throw error;
  }

  return body;
}

function buildInitialAnswers(steps, restoredAnswers = {}) {
  const nextAnswers = {};

  for (const step of steps) {
    const stepAnswers = restoredAnswers?.[step.id] && typeof restoredAnswers[step.id] === 'object'
      ? restoredAnswers[step.id]
      : {};

    nextAnswers[step.id] = {};
    for (const input of step.inputs || []) {
      if (Object.prototype.hasOwnProperty.call(stepAnswers, input.id)) {
        nextAnswers[step.id][input.id] = stepAnswers[input.id];
      } else if (Object.prototype.hasOwnProperty.call(input, 'default')) {
        nextAnswers[step.id][input.id] = input.default;
      } else if (input.type === 'boolean') {
        nextAnswers[step.id][input.id] = false;
      } else {
        nextAnswers[step.id][input.id] = '';
      }
    }

    for (const [key, value] of Object.entries(stepAnswers)) {
      if (!Object.prototype.hasOwnProperty.call(nextAnswers[step.id], key)) {
        nextAnswers[step.id][key] = value;
      }
    }
  }

  return nextAnswers;
}

function buildPayloadInputs(step, stepAnswers = {}) {
  const payload = {};

  for (const input of step.inputs || []) {
    if (Object.prototype.hasOwnProperty.call(stepAnswers, input.id)) {
      payload[input.id] = stepAnswers[input.id];
    } else if (Object.prototype.hasOwnProperty.call(input, 'default')) {
      payload[input.id] = input.default;
    }
  }

  return payload;
}

function downloadText(filename, content) {
  const blob = new Blob([content], { type: 'application/json;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement('a');
  anchor.href = url;
  anchor.download = filename;
  anchor.click();
  URL.revokeObjectURL(url);
}

function formatInputValue(input, value) {
  if (input.type === 'boolean') {
    return Boolean(value);
  }

  if (typeof value === 'number' && Number.isNaN(value)) {
    return '';
  }

  return value ?? '';
}

function getDisplayStepTitle(step) {
  if (!step) {
    return '';
  }

  if (step.id === 'provision-nodes') {
    return 'Deploy Talos Cluster';
  }

  return step.title;
}

function getStepPresentation(step) {
  return {
    icon: step?.icon || '🚀',
    iconArtworkUrl: step?.icon_artwork_url || '',
    projectUrl: step?.project_url || '',
    githubUrl: step?.github_url || '',
    positiveSummary: step?.positive_summary || step?.summary || '',
  };
}

function getStepLinkItems(step) {
  const presentation = getStepPresentation(step);
  return [
    presentation.projectUrl
      ? { label: 'Project', href: presentation.projectUrl }
      : null,
    presentation.githubUrl
      ? { label: 'GitHub', href: presentation.githubUrl }
      : null,
  ].filter(Boolean);
}

function InputField({ stepId, input, value, onChange }) {
  const controlId = `${stepId}-${input.id}`;
  const helpText = input.help || 'Use the value from your Proxmox and cluster plan.';
  const defaultLabel = Object.prototype.hasOwnProperty.call(input, 'default') && input.default !== ''
    ? `Default: ${String(input.default)}`
    : 'No preset default';

  if (input.type === 'boolean') {
    return (
      <label className="wizard-field wizard-field-boolean" htmlFor={controlId}>
        <input
          id={controlId}
          type="checkbox"
          checked={Boolean(value)}
          onChange={(event) => onChange(input.id, event.target.checked)}
        />
        <span>
          <strong>{input.label}</strong>
          <small>{helpText}</small>
          <em>{defaultLabel}</em>
        </span>
      </label>
    );
  }

  if (Array.isArray(input.options) && input.options.length > 0) {
    return (
      <label className="wizard-field" htmlFor={controlId}>
        <span className="wizard-field-label">{input.label}</span>
        <select
          className="wizard-field-select"
          id={controlId}
          value={formatInputValue(input, value)}
          required={input.required}
          onChange={(event) => onChange(input.id, event.target.value)}
        >
          <option value="">Choose an option</option>
          {input.options.map((option) => (
            <option key={option.value} value={option.value}>
              {option.label}
            </option>
          ))}
        </select>
        <small>{helpText}</small>
        <em>{defaultLabel}</em>
      </label>
    );
  }

  if (stepId === 'provision-nodes' && input.id === 'scale_percent') {
    const numericValue = Number.isFinite(Number(value)) ? Number(value) : 30;

    return (
      <label className="wizard-field wizard-field-range" htmlFor={controlId}>
        <span className="wizard-field-range-head">
          <span className="wizard-field-label">{input.label}</span>
          <strong className="wizard-field-range-value">{numericValue}%</strong>
        </span>
        <input
          id={controlId}
          type="range"
          min={input.min}
          max={input.max}
          step={1}
          value={numericValue}
          onChange={(event) => onChange(input.id, event.target.valueAsNumber)}
        />
        <small>{helpText}</small>
        <em>{defaultLabel}</em>
      </label>
    );
  }

  const inputType = input.type === 'integer' ? 'number' : 'text';

  const fieldClassName = input.id === 'dns_servers'
    ? 'wizard-field wizard-field-compact'
    : 'wizard-field';

  return (
    <label className={fieldClassName} htmlFor={controlId}>
      <span className="wizard-field-label">{input.label}</span>
      <input
        id={controlId}
        type={inputType}
        value={formatInputValue(input, value)}
        onChange={(event) => onChange(input.id, input.type === 'integer' ? event.target.valueAsNumber : event.target.value)}
        min={input.min}
        max={input.max}
        placeholder={input.help || input.label}
        inputMode={input.type === 'integer' ? 'numeric' : input.type === 'ipv4' ? 'decimal' : 'text'}
      />
      <small>{helpText}</small>
      <em>{defaultLabel}</em>
    </label>
  );
}

const PROVISION_VM_INPUT_IDS = [
  'scale_percent',
  'name',
  'controlplane_count',
  'worker_count',
  'cpu_cores',
  'memory_mb',
  'disk_gb',
  'start_vmid',
];

const PROVISION_NETWORK_INPUT_IDS = [
  'bridge',
  'vip_ip',
  'node_prefix_length',
  'gateway_ip',
  'dns_servers',
];

function getProvisionInputGroups(inputs = []) {
  const lookup = new Map(inputs.map((input) => [input.id, input]));
  return {
    vmInputs: PROVISION_VM_INPUT_IDS.map((id) => lookup.get(id)).filter(Boolean),
    networkInputs: PROVISION_NETWORK_INPUT_IDS.map((id) => lookup.get(id)).filter(Boolean),
  };
}

function KeyValueList({ items, emptyLabel }) {
  if (!items.length) {
    return <p className="wizard-empty">{emptyLabel}</p>;
  }

  return (
    <dl className="wizard-kv-list">
      {items.map((item) => (
        <div key={item.label} className="wizard-kv-item">
          <dt>{item.label}</dt>
          <dd>{item.value}</dd>
        </div>
      ))}
    </dl>
  );
}

function PlacementBoard({
  board,
  draggingVmName,
  onDragStart,
  onDragEnd,
  onDropVm,
  onReset,
}) {
  if (!board?.hostCards?.length) {
    return (
      <section className="wizard-placement-empty">
        <p className="wizard-empty">No Proxmox host data is available yet. The wizard can still scale the cluster, but the placement board needs host resources to show draggable VMs.</p>
      </section>
    );
  }

  return (
    <section className="wizard-placement-board" aria-label="Cluster placement board">
      <div className="wizard-input-block-head">
        <div>
          <p className="eyebrow">VM landing</p>
          <h3>Drag Talos VMs between Proxmox hosts</h3>
        </div>
        <div className="wizard-card-actions wizard-card-actions-inline">
          <p className="wizard-input-block-note">
            Sizing comes first. After that, drag cards to land each VM on the right Proxmox host.
            {' '}
            The board keeps refreshing so the suggestion stays aligned with live running VMs, but your placements stay fixed until you retry.
          </p>
          <button className="button button-secondary" type="button" onClick={onReset}>
            Retry balanced suggestion
          </button>
        </div>
      </div>

      <div className="wizard-placement-grid">
        {board.hostCards.map((host) => (
          <article
            key={host.id}
            className={`wizard-placement-host ${draggingVmName ? 'is-droppable' : ''}`}
            onDragOver={(event) => event.preventDefault()}
            onDrop={(event) => {
              event.preventDefault();
              onDropVm(host.id);
            }}
          >
            <header className="wizard-placement-host-head">
              <div>
                <strong>{host.name}</strong>
                <span>{host.status} · {host.activeVmCount} running VM{host.activeVmCount === 1 ? '' : 's'}</span>
              </div>
              <div className="wizard-placement-host-capacity">
                <span>{Math.round(host.freeCpuCores)} CPU free</span>
                <span>{formatMemoryMb(host.freeMemoryMb)} free</span>
                <span>{Math.round(host.freeDiskGb)} GB disk free</span>
              </div>
            </header>

            <div className="wizard-placement-host-body">
            {host.assignments.length > 0 ? (
              host.assignments.map((vm) => (
                <button
                  key={vm.name}
                  className={`wizard-vm-card ${draggingVmName === vm.name ? 'is-dragging' : ''} ${vm.assignmentSource === 'user-selected' ? 'is-user-selected' : vm.assignmentSource === 'suggested' ? 'is-suggested' : 'is-unassigned'}`}
                  type="button"
                  draggable
                  onDragStart={(event) => onDragStart(event, vm.name)}
                  onDragEnd={onDragEnd}
                >
                  <span className="wizard-vm-card-title">{vm.label}</span>
                  <strong>{vm.name}</strong>
                  <small>VMID {vm.vmid} | {vm.cpu} CPU | {formatMemoryMb(vm.memory_mb)} RAM | {vm.disk_gb} GB disk</small>
                  <em>
                    {vm.assignmentSource === 'user-selected'
                      ? `You placed this VM on ${host.name}.`
                      : vm.assignmentSource === 'suggested'
                        ? `Suggested here to balance CPU, memory, and disk across the cluster.`
                        : 'This VM is not assigned yet.'}
                  </em>
                </button>
              ))
            ) : (
                <p className="wizard-empty wizard-empty-inline">Drop a VM here.</p>
              )}
            </div>
          </article>
        ))}
      </div>

      {board.unassigned?.length ? (
        <article className="wizard-placement-host wizard-placement-unassigned">
          <header className="wizard-placement-host-head">
            <div>
              <strong>Unassigned</strong>
              <span>Drag these VMs onto a Proxmox host</span>
            </div>
          </header>
          <div className="wizard-placement-host-body">
            {board.unassigned.map((vm) => (
              <button
                key={vm.name}
                className={`wizard-vm-card ${draggingVmName === vm.name ? 'is-dragging' : ''} ${vm.assignmentSource === 'user-selected' ? 'is-user-selected' : vm.assignmentSource === 'suggested' ? 'is-suggested' : 'is-unassigned'}`}
                type="button"
                draggable
                onDragStart={(event) => onDragStart(event, vm.name)}
                onDragEnd={onDragEnd}
              >
                <span className="wizard-vm-card-title">{vm.label}</span>
                <strong>{vm.name}</strong>
                <small>VMID {vm.vmid} | {vm.cpu} CPU | {formatMemoryMb(vm.memory_mb)} RAM | {vm.disk_gb} GB disk</small>
                <em>Drag this VM onto a host to override the balanced suggestion.</em>
              </button>
            ))}
          </div>
        </article>
      ) : null}
    </section>
  );
}

function buildPlacementRationale(vm, currentHostName, suggestedHostName) {
  if (!currentHostName) {
    return `Suggested for ${suggestedHostName || 'a free host'} to keep the cluster balanced.`;
  }

  if (currentHostName === suggestedHostName) {
    return `Suggested here to keep CPU, memory, and disk pressure balanced across the cluster.`;
  }

  return `Manually moved from ${suggestedHostName || 'the suggested host'} to ${currentHostName}.`;
}

function App() {
  const importInputRef = useRef(null);
  const liveOutputRef = useRef(null);
  const busyRef = useRef(false);
  const clusterIdRef = useRef('');
  const clusterCreatedAtRef = useRef('');
  const clusterInstanceIdRef = useRef('');
  const selectedStepIdRef = useRef('');
  const answersRef = useRef({});
  const hydratedRef = useRef(false);
  const provisionDirtyFieldsRef = useRef(new Set());
  const provisionSuggestionKeyRef = useRef('');
  const provisionSuggestionSnapshotRef = useRef({});

  const [catalog, setCatalog] = useState({ categories: [], errors: [] });
  const [health, setHealth] = useState({ ok: false });
  const [selectedStepId, setSelectedStepId] = useState('');
  const [answers, setAnswers] = useState({});
  const [clusterId, setClusterId] = useState('');
  const [clusterCreatedAt, setClusterCreatedAt] = useState('');
  const [clusterInstanceId, setClusterInstanceId] = useState('');
  const [cluster, setCluster] = useState(null);
  const [proxmoxResources, setProxmoxResources] = useState(null);
  const [logs, setLogs] = useState([]);
  const [draggingVmName, setDraggingVmName] = useState('');
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState('');
  const [error, setError] = useState('');
  const [activeJob, setActiveJob] = useState(null);
  const [provisionSuggestionsReadyState, setProvisionSuggestionsReadyState] = useState(false);
  const placementSuggestionKeyRef = useRef('');

  useEffect(() => {
    const restored = restoreUiState(window.localStorage.getItem(STORAGE_KEY));
    setSelectedStepId(restored.selectedStepId);
    setClusterId(restored.clusterId);
    setClusterCreatedAt(restored.clusterCreatedAt);
    setClusterInstanceId(restored.clusterInstanceId);
    setAnswers(restored.answers);
    hydratedRef.current = true;
  }, []);

  useEffect(() => {
    if (!hydratedRef.current) return;

    window.localStorage.setItem(
      STORAGE_KEY,
      serializeUiState({
        selectedStepId,
        answers,
        clusterId,
        clusterCreatedAt,
        clusterInstanceId,
      }),
    );
  }, [selectedStepId, answers, clusterId, clusterCreatedAt, clusterInstanceId]);

  useEffect(() => {
    clusterIdRef.current = clusterId;
  }, [clusterId]);

  useEffect(() => {
    clusterCreatedAtRef.current = clusterCreatedAt;
  }, [clusterCreatedAt]);

  useEffect(() => {
    clusterInstanceIdRef.current = clusterInstanceId;
  }, [clusterInstanceId]);

  useEffect(() => {
    selectedStepIdRef.current = selectedStepId;
  }, [selectedStepId]);

  useEffect(() => {
    answersRef.current = answers;
  }, [answers]);

  const setupSteps = useMemo(() => getWizardSteps(catalog), [catalog]);
  const initialAnswers = useMemo(() => buildInitialAnswers(setupSteps, answers), [setupSteps, answers]);
  const model = useMemo(() => {
    return getMissionControlModel({
      catalog,
      selectedStepId,
      logs,
      cluster,
      health,
      error,
      busy,
      answers: initialAnswers,
    });
  }, [answers, busy, catalog, cluster, error, health, initialAnswers, logs, selectedStepId]);

  const visibleActiveJob = useMemo(() => {
    if (activeJob?.id) {
      return activeJob;
    }

    const activeStep = model.steps.find((step) => step.latest_job && ['pending', 'running', 'cancel_requested'].includes(step.latest_job.status));
    if (!activeStep?.latest_job) {
      return null;
    }

    return {
      id: activeStep.latest_job.id,
      stepId: activeStep.id,
      clusterId: activeStep.latest_job.cluster_id || clusterIdRef.current || '',
      clusterInstanceId: activeStep.latest_job.cluster_instance_id || clusterInstanceIdRef.current || '',
      status: activeStep.latest_job.status,
    };
  }, [activeJob, clusterIdRef, clusterInstanceIdRef, model.steps]);

  useEffect(() => {
    if (!hydratedRef.current) return;

    let cancelled = false;

    const refreshSnapshot = async () => {
      if (busyRef.current || cancelled) {
        return;
      }

      try {
        await refreshWizardSnapshot({
          requestJson,
          clusterIdRef,
          clusterInstanceIdRef,
          selectedStepIdRef,
          clusterCreatedAtRef,
          answersRef,
          provisionDirtyFieldsRef,
          provisionSuggestionKeyRef,
          provisionSuggestionSnapshotRef,
          placementSuggestionKeyRef,
          setHealth,
          setCatalog,
          setProxmoxResources,
          setClusterId,
          setClusterCreatedAt,
          setClusterInstanceId,
          setSelectedStepId,
          setCluster,
          setLogs,
          setActiveJob,
          setAnswers,
          setNotice,
          setError,
          setProvisionSuggestionsReady: setProvisionSuggestionsReadyState,
        });
      } catch (refreshError) {
        if (!cancelled) {
          setError(refreshError instanceof Error ? refreshError.message : 'Failed to refresh wizard state');
        }
      }
    };

    refreshSnapshot();
    const timer = window.setInterval(refreshSnapshot, POLL_INTERVAL_MS);

    return () => {
      cancelled = true;
      window.clearInterval(timer);
    };
  }, []);

  useEffect(() => {
    if (!hydratedRef.current) return;

    if (!clusterId) {
      setCluster(null);
      return;
    }

    let cancelled = false;

    const refreshCluster = async () => {
      try {
        const data = await requestJson(`/api/clusters/${encodeURIComponent(clusterId)}`);
        if (!cancelled) {
          const nextClusterInstanceId = typeof data?.cluster_instance_id === 'string' ? data.cluster_instance_id : '';
          const nextCreatedAt = typeof data?.created_at === 'string' ? data.created_at : '';
          const previousCreatedAt = clusterCreatedAtRef.current || '';
          const previousClusterInstanceId = clusterInstanceIdRef.current || '';
          const hasProvisionDraft = Boolean(answersRef.current && Object.prototype.hasOwnProperty.call(answersRef.current, 'provision-nodes'));
          if (shouldResetRecreatedClusterDraft({
            previousClusterInstanceId,
            nextClusterInstanceId,
            previousCreatedAt,
            nextCreatedAt,
            hasProvisionDraft,
          })) {
            recoverRecreatedClusterState({
              setClusterCreatedAt,
              setClusterInstanceId,
              setSelectedStepId,
              setCluster,
              setLogs,
              setActiveJob,
              setAnswers,
              setError,
              setNotice,
              clusterCreatedAtRef,
              clusterInstanceIdRef,
              selectedStepIdRef,
              answersRef,
            provisionDirtyFieldsRef,
            provisionSuggestionKeyRef,
            provisionSuggestionSnapshotRef,
            placementSuggestionKeyRef,
            setProvisionSuggestionsReady: setProvisionSuggestionsReadyState,
          });
          }

          if (nextCreatedAt && nextCreatedAt !== clusterCreatedAtRef.current) {
            clusterCreatedAtRef.current = nextCreatedAt;
            setClusterCreatedAt(nextCreatedAt);
          }

          if (nextClusterInstanceId && nextClusterInstanceId !== clusterInstanceIdRef.current) {
            clusterInstanceIdRef.current = nextClusterInstanceId;
            setClusterInstanceId(nextClusterInstanceId);
          }

          setCluster(data);
        }
      } catch (error) {
        if (cancelled) {
          return;
        }

        if (isMissingClusterError(error)) {
          recoverMissingClusterState({
            setClusterId,
            setClusterCreatedAt,
            setClusterInstanceId,
            setSelectedStepId,
            setCluster,
            setLogs,
            setActiveJob,
            setAnswers,
            setError,
            setNotice,
            clusterIdRef,
            clusterCreatedAtRef,
            clusterInstanceIdRef,
            selectedStepIdRef,
            answersRef,
            provisionDirtyFieldsRef,
            provisionSuggestionKeyRef,
            provisionSuggestionSnapshotRef,
            placementSuggestionKeyRef,
            setProvisionSuggestionsReady: setProvisionSuggestionsReadyState,
          });
          return;
        }

        setCluster(null);
      }
    };

    refreshCluster();
    return () => {
      cancelled = true;
    };
  }, [clusterId]);

  useEffect(() => {
    busyRef.current = busy;
  }, [busy]);

  // Auto-scroll disabled: users should control their own scroll position.
  // The live output panel is visible in the layout without forced scrolling.

  async function pollJob(jobId) {
    let latestJob = null;
    let latestLogs = [];

    for (;;) {
      const [jobData, logsData] = await Promise.all([
        requestJson(`/api/jobs/${encodeURIComponent(jobId)}`),
        requestJson(`/api/jobs/${encodeURIComponent(jobId)}/logs`),
      ]);

      latestJob = jobData;
      latestLogs = logsData?.lines || [];
      setLogs(latestLogs);

      if (jobData.status === 'pending' || jobData.status === 'running' || jobData.status === 'cancel_requested') {
        await sleep(1600);
        continue;
      }

      return { job: latestJob, logs: latestLogs };
    }
  }

  async function handleCancelActiveJob() {
    if (!visibleActiveJob?.id || !['pending', 'running', 'cancel_requested'].includes(visibleActiveJob.status)) {
      return;
    }

    const jobId = visibleActiveJob.id;
    setError('');
    setNotice(`Stopping job ${jobId}...`);
    setActiveJob((current) => (current?.id === jobId ? { ...current, status: 'cancel_requested' } : current));

    try {
      await requestJson(`/api/jobs/${encodeURIComponent(jobId)}/cancel`, { method: 'POST' });
    } catch (cancelError) {
      const message = cancelError instanceof Error ? cancelError.message : `Failed to stop job ${jobId}`;
      setError(message);
      setNotice(`Could not stop job ${jobId}.`);
      setActiveJob((current) => (current?.id === jobId ? { ...current, status: 'running' } : current));
    }
  }

  async function ensureProvisionDraft(step, currentDraft = {}) {
    const managementIp = window.location.hostname;
    const managementIpParts = managementIp.split('.').map((part) => Number(part));
    const hasValidManagementIp = managementIpParts.length === 4
      && managementIpParts.every((part) => Number.isInteger(part) && part >= 0 && part <= 255);

    if (!hasValidManagementIp) {
      return currentDraft;
    }

    const nodeCount = getProvisionNodeCount(step.inputs || [], currentDraft);
    const suggestionKey = `${managementIp}:${nodeCount}`;
    const previousSuggested = buildSuggestedProvisionInputs(provisionSuggestionSnapshotRef.current);

    let suggestionData = provisionSuggestionSnapshotRef.current;
    if (provisionSuggestionKeyRef.current !== suggestionKey || !suggestionData || Object.keys(suggestionData).length === 0) {
      suggestionData = await requestJson(
        `/api/ip-suggestions?management_ip=${encodeURIComponent(managementIp)}&node_count=${nodeCount}`,
      );
      provisionSuggestionKeyRef.current = suggestionKey;
      provisionSuggestionSnapshotRef.current = suggestionData;
    }

    const merged = mergeSuggestedProvisionDraft({
      currentDraft,
      previousSuggested,
      suggestionData,
      stepInputs: step.inputs || [],
      dirtyFields: Object.fromEntries([...provisionDirtyFieldsRef.current].map((fieldId) => [fieldId, true])),
    });

    setAnswers((current) => ({
      ...current,
      [step.id]: merged,
    }));

    return merged;
  }

  async function executeStep(step, clusterIdOverride = clusterIdRef.current, options = {}) {
    const { manageBusy = true } = options;
    const currentStepDraft = answersRef.current?.[step.id] || {};
    const draft = currentStepDraft;
    const body = {
      inputs: buildPayloadInputs(step, draft),
    };

    if (clusterInstanceIdRef.current) {
      body.cluster_instance_id = clusterInstanceIdRef.current;
    }

    if (step.id !== 'provision-nodes' && clusterIdOverride) {
      body.cluster_id = clusterIdOverride;
    }

    if (step.id === 'provision-nodes') {
      if (!placementBoard?.hostCards?.length) {
        const message = 'Waiting for Proxmox host data before starting Deploy Talos Cluster.';
        setError(message);
        setNotice(message);
        return { ok: false, error: message };
      }

      const placement = buildProvisionPlacementBoard(step.inputs || [], draft, proxmoxResources);
      const vmIpRows = buildProvisionVmIpRows(placement.vmPlan, draft, provisionSuggestionSnapshotRef.current);
      const vmIpValidation = validateProvisionVmIpRows(vmIpRows);
      if (!vmIpValidation.ok) {
        const message = vmIpValidation.error || 'VM IP addresses must be valid before starting step 1.';
        setError(message);
        setNotice(message);
        return { ok: false, error: message };
      }

      body.vm_node_map = placement.vmNodeMap;
      body.vm_ip_map = buildProvisionVmIpMap(vmIpRows);
    }

    if (manageBusy) {
      setBusy(true);
    }
    setError('');
    setNotice(`Queued ${step.title}.`);
    setSelectedStepId(step.id);
    setActiveJob({ id: null, stepId: step.id, status: 'starting' });
    setLogs([]);

    try {
      const response = await requestJson(`/api/steps/${encodeURIComponent(step.id)}/execute`, {
        method: 'POST',
        body: JSON.stringify(body),
      });

      const nextClusterId = response.cluster_id || clusterIdOverride || '';
      const nextClusterInstanceId = response.cluster_instance_id || clusterInstanceIdRef.current || '';
      setActiveJob({
        id: response.job_id,
        stepId: step.id,
        clusterId: nextClusterId,
        clusterInstanceId: nextClusterInstanceId,
        status: 'running',
      });

      const terminal = await pollJob(response.job_id);
      setActiveJob({
        id: response.job_id,
        stepId: step.id,
        clusterId: nextClusterId,
        clusterInstanceId: nextClusterInstanceId,
        status: terminal.job.status,
      });

      if (nextClusterId && nextClusterId !== clusterIdRef.current) {
        setClusterId(nextClusterId);
      }
      if (nextClusterInstanceId && nextClusterInstanceId !== clusterInstanceIdRef.current) {
        clusterInstanceIdRef.current = nextClusterInstanceId;
        setClusterInstanceId(nextClusterInstanceId);
      }

      if (terminal.job.status === 'failed') {
        const failure = terminal.job.error || step.state?.error || `${step.title} failed`;
        setError(failure);
        setNotice(`Failed to finish ${step.title}.`);
      } else if (terminal.job.status === 'canceled') {
        setNotice(`${step.title} was stopped.`);
      } else {
        setNotice(`${step.title} completed successfully.`);
      }

      const refreshedCatalog = await refreshWizardSnapshot({
        requestJson,
        clusterIdRef,
        clusterInstanceIdRef,
        selectedStepIdRef,
        clusterCreatedAtRef,
        answersRef,
        provisionDirtyFieldsRef,
        provisionSuggestionKeyRef,
        provisionSuggestionSnapshotRef,
        placementSuggestionKeyRef,
        setHealth,
        setCatalog,
        setProxmoxResources,
        setClusterId,
        setClusterCreatedAt,
        setClusterInstanceId,
        setSelectedStepId,
        setCluster,
        setLogs,
        setActiveJob,
        setAnswers,
        setNotice,
        setProvisionSuggestionsReady: setProvisionSuggestionsReadyState,
        clusterIdOverride: nextClusterId,
        clearError: false,
        setError,
      });

      return {
        ok: terminal.job.status === 'succeeded',
        job: terminal.job,
        clusterId: nextClusterId,
        catalog: refreshedCatalog,
      };
    } catch (stepError) {
      const message = stepError instanceof Error ? stepError.message : `Failed to execute ${step.title}`;
      setError(message);
      setNotice(`Could not queue ${step.title}.`);
      return { ok: false, error: message };
    } finally {
      if (manageBusy) {
        setBusy(false);
        setActiveJob(null);
      }
    }
  }

  async function handlePrimaryAction() {
    if (!model.activeStep || model.primaryAction.disabled || busyRef.current) {
      return;
    }

    busyRef.current = true;
    try {
      if (model.activeStep.id === 'provision-nodes' && !provisionStepValid) {
        const message = provisionVmIpValidation.error || 'Step 1 is still preparing. Wait until the button says Start step 1.';
        setNotice(message);
        return;
      }

      if (model.primaryAction.type === 'unskip') {
        await handleUnskipAndExecute(model.activeStep);
        return;
      }

      if (model.primaryAction.type === 'advance' && model.nextStep) {
        setSelectedStepId(model.nextStep.id);
        setNotice(`Moved to ${model.nextStep.title}.`);
        return;
      }

      if (model.primaryAction.type === 'finish') {
        setNotice('The cluster bootstrap is finished. Export the answers file to keep this configuration.');
        return;
      }

      await executeStep(model.activeStep);
    } finally {
      busyRef.current = false;
    }
  }

  async function handleReinstallStep(step) {
    if (!step || step.status !== 'done') {
      return;
    }

    await executeStep(step);
  }

  async function handleSkipStep(step) {
    if (!step || step.status === 'running' || step.status === 'done') {
      return;
    }

    const confirmed = window.confirm(`Are you sure you want to skip "${step.title}"? You can run this step later.`);
    if (!confirmed) {
      return;
    }

    setBusy(true);
    setError('');
    try {
      const response = await fetch(`/api/steps/${step.id}/skip`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ cluster_id: clusterIdRef.current }),
      });
      if (!response.ok) {
        const body = await response.json().catch(() => ({}));
        throw new Error(body.error || `Failed to skip ${step.title}`);
      }
      setNotice(`Skipped "${step.title}".`);
      await refreshWizardSnapshot({
        requestJson,
        clusterIdRef,
        clusterInstanceIdRef,
        selectedStepIdRef,
        clusterCreatedAtRef,
        answersRef,
        provisionDirtyFieldsRef,
        provisionSuggestionKeyRef,
        provisionSuggestionSnapshotRef,
        placementSuggestionKeyRef,
        setHealth,
        setCatalog,
        setProxmoxResources,
        setClusterId,
        setClusterCreatedAt,
        setClusterInstanceId,
        setSelectedStepId,
        setCluster,
        setLogs,
        setActiveJob,
        setAnswers,
        setNotice,
        setError,
        setProvisionSuggestionsReady: setProvisionSuggestionsReadyState,
      });
    } catch (skipError) {
      const message = skipError instanceof Error ? skipError.message : `Failed to skip ${step.title}`;
      setError(message);
    } finally {
      setBusy(false);
    }
  }

  async function handleUnskipAndExecute(step) {
    if (!step || busy || step.status !== 'skipped') {
      return;
    }

    setBusy(true);
    setError('');
    try {
      const response = await fetch(`/api/steps/${step.id}/unskip`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ cluster_id: clusterIdRef.current }),
      });
      if (!response.ok) {
        const body = await response.json().catch(() => ({}));
        throw new Error(body.error || `Failed to unskip ${step.title}`);
      }
      await refreshWizardSnapshot({
        requestJson,
        clusterIdRef,
        clusterInstanceIdRef,
        selectedStepIdRef,
        clusterCreatedAtRef,
        answersRef,
        provisionDirtyFieldsRef,
        provisionSuggestionKeyRef,
        provisionSuggestionSnapshotRef,
        placementSuggestionKeyRef,
        setHealth,
        setCatalog,
        setProxmoxResources,
        setClusterId,
        setClusterCreatedAt,
        setClusterInstanceId,
        setSelectedStepId,
        setCluster,
        setLogs,
        setActiveJob,
        setAnswers,
        setNotice,
        setError,
        setProvisionSuggestionsReady: setProvisionSuggestionsReadyState,
      });
      const refreshedStep = { ...step, status: 'ready' };
      await executeStep(refreshedStep);
    } catch (err) {
      const message = err instanceof Error ? err.message : `Failed to run ${step.title}`;
      setError(message);
    } finally {
      setBusy(false);
    }
  }

  async function handleInstallAllSteps() {
    if (!setupSteps.length || busyRef.current) {
      return;
    }

    const pendingSteps = getWizardSteps(catalog).filter(
      (step) => step.status !== 'done' && step.status !== 'skipped'
    );
    if (!pendingSteps.length) {
      setNotice('Every setup step is already complete.');
      return;
    }

    setBusy(true);
    setError('');
    setNotice('Installing all setup steps in order.');

    try {
      let nextClusterId = clusterIdRef.current;
      let currentCatalogData = catalog;

      for (const step of pendingSteps) {
        const currentCatalog = getWizardSteps(currentCatalogData);
        const currentStep = currentCatalog.find((candidate) => candidate.id === step.id) || step;

        if (currentStep.status === 'done') {
          continue;
        }

        if (currentStep.status === 'locked') {
          throw new Error(`${currentStep.title} is locked until its dependencies are complete.`);
        }

        const result = await executeStep(currentStep, nextClusterId, { manageBusy: false });
        nextClusterId = result.clusterId || nextClusterId;

        if (!result.ok) {
          break;
        }

        currentCatalogData = result.catalog || currentCatalogData;
      }
    } finally {
      setBusy(false);
      setActiveJob(null);
    }
  }

  function updateAnswer(stepId, inputId, value) {
    if (stepId === 'provision-nodes' && inputId !== 'scale_percent' && PROVISION_AUTOSCALED_FIELDS.includes(inputId)) {
      provisionDirtyFieldsRef.current.add(inputId);
    }

    setAnswers((current) => {
      const currentStep = current[stepId] || {};
      const nextStep = {
        ...currentStep,
        [inputId]: value,
      };

      if (stepId === 'provision-nodes' && inputId === 'scale_percent') {
        const currentScale = Number.isFinite(Number(value)) ? Number(value) : 30;
        return {
          ...current,
          [stepId]: buildScaledProvisionInputs(
            currentScale,
            model.activeStep?.inputs || [],
            nextStep,
            provisionDirtyFieldsRef.current,
            proxmoxResources,
          ),
        };
      }

      return {
        ...current,
        [stepId]: nextStep,
      };
    });
  }

  function updatePlacement(vmName, hostName) {
    if (!vmName || !hostName || model.activeStep?.id !== 'provision-nodes') {
      return;
    }

    const currentMap = currentDraft.vm_node_map && typeof currentDraft.vm_node_map === 'object'
      ? currentDraft.vm_node_map
      : {};

    updateAnswer(model.activeStep.id, 'vm_node_map', {
      ...currentMap,
      [vmName]: hostName,
    });
  }

  function resetPlacementToSuggested() {
    if (!placementBoard || model.activeStep?.id !== 'provision-nodes') {
      return;
    }

    updateAnswer(model.activeStep.id, 'vm_node_map', placementBoard.suggestedVmNodeMap || {});
  }

  function handleExportAnswers() {
    const snapshot = serializeUiState({
      selectedStepId,
      answers: answersRef.current,
      clusterId: clusterIdRef.current,
      clusterCreatedAt: clusterCreatedAtRef.current,
      clusterInstanceId: clusterInstanceIdRef.current,
    });
    const filename = buildWizardExportFilename({
      clusterName: cluster?.name || '',
      clusterId: clusterIdRef.current || cluster?.id || '',
    });
    downloadText(filename, snapshot);
    setNotice('Downloaded the current wizard answers.');
  }

  function handleImportClick() {
    importInputRef.current?.click();
  }

  async function handleImportFile(event) {
    const file = event.target.files?.[0];
    event.target.value = '';

    if (!file) {
      return;
    }

    try {
      const content = await file.text();
      const imported = restoreUiState(content);
      const importedAnswers = imported.answers && typeof imported.answers === 'object' ? imported.answers : {};
      setSelectedStepId(imported.selectedStepId);
      setClusterId(imported.clusterId);
      setClusterCreatedAt(imported.clusterCreatedAt);
      setClusterInstanceId(imported.clusterInstanceId);
      setAnswers((current) => {
        const next = { ...current };
        for (const [stepId, stepAnswers] of Object.entries(importedAnswers)) {
          next[stepId] = {
            ...(current[stepId] || {}),
            ...(stepAnswers && typeof stepAnswers === 'object' ? stepAnswers : {}),
          };
        }
        return next;
      });
      placementSuggestionKeyRef.current = '';
      provisionSuggestionKeyRef.current = '';
      provisionSuggestionSnapshotRef.current = {};
      provisionDirtyFieldsRef.current = new Set();
      setProvisionSuggestionsReadyState(false);
      setNotice('Imported saved wizard answers.');
    } catch (importError) {
      const message = importError instanceof Error ? importError.message : 'Could not import the answers file.';
      setError(message);
    }
  }

  const topMetrics = [
    { label: 'Progress', value: `${model.progress.completedSteps}/${model.progress.totalSteps}` },
    { label: 'Current step', value: model.activeStep ? `${model.progress.stepIndex}` : '0' },
    { label: 'Cluster', value: cluster?.id || clusterId || 'Not created' },
  ];

  const currentDraft = model.activeStep
    ? buildInitialAnswers([model.activeStep], answers)[model.activeStep.id]
    : {};
  useEffect(() => {
    if (model.activeStep?.id !== 'provision-nodes') {
      setProvisionSuggestionsReadyState(false);
      return;
    }

    const managementIp = window.location.hostname;
    const managementIpParts = managementIp.split('.').map((part) => Number(part));
    const hasValidManagementIp = managementIpParts.length === 4
      && managementIpParts.every((part) => Number.isInteger(part) && part >= 0 && part <= 255);

    if (!hasValidManagementIp) {
      setProvisionSuggestionsReadyState(false);
      return;
    }

    const suggestionKey = `${managementIp}:${getProvisionNodeCount(model.activeStep.inputs || [], currentDraft)}`;

    setProvisionSuggestionsReadyState(
      provisionSuggestionKeyRef.current === suggestionKey
      && Object.keys(provisionSuggestionSnapshotRef.current || {}).length > 0,
    );
  }, [clusterInstanceId, currentDraft.controlplane_count, currentDraft.worker_count, model.activeStep?.id]);

  const placementBoard = model.activeStep?.id === 'provision-nodes'
    ? buildProvisionPlacementBoard(model.activeStep.inputs || [], currentDraft, proxmoxResources)
    : null;
  const provisionVmIpRows = model.activeStep?.id === 'provision-nodes'
    ? buildProvisionVmIpRows(placementBoard?.vmPlan || [], currentDraft, provisionSuggestionSnapshotRef.current)
    : [];
  const provisionVmIpValidation = model.activeStep?.id === 'provision-nodes'
    ? validateProvisionVmIpRows(provisionVmIpRows)
    : { ok: true, error: '', invalidRows: [], duplicateRows: [] };
  const provisionSubnet = provisionSuggestionSnapshotRef.current?.subnet
    || (currentDraft.vip_ip
      ? `${String(currentDraft.vip_ip).split('.').slice(0, 3).join('.')}.0/24`
      : '192.168.1.0/24');
  const provisionInputGroups = model.activeStep?.id === 'provision-nodes'
    ? getProvisionInputGroups(model.activeStep.inputs || [])
    : { vmInputs: [], networkInputs: [] };
  const provisionScaleSummary = model.activeStep?.id === 'provision-nodes'
    ? buildProvisionScaleSummary(
      currentDraft.scale_percent ?? 30,
      model.activeStep.inputs || [],
      currentDraft,
      proxmoxResources,
    )
    : null;
  const provisionSuggestionKey = model.activeStep?.id === 'provision-nodes'
    ? `${window.location.hostname}:${getProvisionNodeCount(model.activeStep.inputs || [], currentDraft)}`
    : '';
  const provisionPlacementReady = model.activeStep?.id !== 'provision-nodes' || Boolean(placementBoard?.hostCards?.length);
  const provisionSuggestionsReady = isProvisionSuggestionReady({
    activeStepId: model.activeStep?.id || '',
    suggestionKey: provisionSuggestionKey,
    currentSuggestionKey: provisionSuggestionKeyRef.current,
    suggestionSnapshot: provisionSuggestionSnapshotRef.current,
  });
  const provisionStepReady = provisionPlacementReady && provisionSuggestionsReady;
  const provisionStepValid = provisionStepReady && provisionVmIpValidation.ok;
  const stepOnePending = model.activeStep?.id === 'provision-nodes' && !provisionStepReady;
  const primaryActionDisabled = model.primaryAction.disabled || !provisionStepValid;
  const primaryActionLabel = stepOnePending
    ? (!provisionPlacementReady ? 'Loading placement data…' : 'Loading step 1…')
    : model.primaryAction.label;
  const primaryActionHelperText = stepOnePending
    ? !provisionPlacementReady
      ? 'Waiting for Proxmox host data before starting step 1.'
      : 'Waiting for step 1 suggestions to load.'
    : !provisionVmIpValidation.ok && model.activeStep?.id === 'provision-nodes'
      ? provisionVmIpValidation.error
      : model.primaryAction.helperText;

  useEffect(() => {
    if (model.activeStep?.id !== 'provision-nodes') {
      return;
    }

    const managementIp = window.location.hostname;
    const managementIpParts = managementIp.split('.').map((part) => Number(part));
    const hasValidManagementIp = managementIpParts.length === 4
      && managementIpParts.every((part) => Number.isInteger(part) && part >= 0 && part <= 255);

    if (!hasValidManagementIp) {
      return;
    }

    const controlplaneCount = Number.isFinite(Number(currentDraft.controlplane_count))
      ? Number(currentDraft.controlplane_count)
      : 1;
    const workerCount = Number.isFinite(Number(currentDraft.worker_count))
      ? Number(currentDraft.worker_count)
      : 0;
    const nodeCount = Math.max(1, controlplaneCount + workerCount);
    const suggestionKey = `${managementIp}:${nodeCount}`;

    if (provisionSuggestionKeyRef.current === suggestionKey
      && Object.keys(provisionSuggestionSnapshotRef.current || {}).length > 0) {
      return;
    }

    provisionSuggestionKeyRef.current = suggestionKey;
    provisionSuggestionSnapshotRef.current = {};
    let cancelled = false;

    (async () => {
      try {
        const suggestionData = await requestJson(
          `/api/ip-suggestions?management_ip=${encodeURIComponent(managementIp)}&node_count=${nodeCount}`,
        );

        if (cancelled) {
          return;
        }

        setAnswers((current) => {
          const currentStep = current[model.activeStep.id] || {};
          const merged = mergeSuggestedProvisionDraft({
            currentDraft: currentStep,
            previousSuggested: buildSuggestedProvisionInputs(provisionSuggestionSnapshotRef.current),
            suggestionData,
            stepInputs: model.activeStep.inputs || [],
            dirtyFields: Object.fromEntries([...provisionDirtyFieldsRef.current].map((fieldId) => [fieldId, true])),
          });

          return {
            ...current,
            [model.activeStep.id]: merged,
          };
        });

        provisionSuggestionSnapshotRef.current = suggestionData;
      } catch {
        if (!cancelled) {
          provisionSuggestionSnapshotRef.current = {};
        }
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [clusterInstanceId, currentDraft.controlplane_count, currentDraft.worker_count, model.activeStep?.id]);

  useEffect(() => {
    if (!placementBoard || model.activeStep?.id !== 'provision-nodes') {
      return;
    }

    const suggestionKey = `${clusterInstanceIdRef.current || clusterIdRef.current || ''}:${model.activeStep.id}`;
    const currentMap = currentDraft.vm_node_map && typeof currentDraft.vm_node_map === 'object'
      ? currentDraft.vm_node_map
      : {};
    const hasPlacement = Object.keys(currentMap).length > 0;

    if (hasPlacement) {
      placementSuggestionKeyRef.current = suggestionKey;
      return;
    }

    if (placementSuggestionKeyRef.current === suggestionKey) {
      return;
    }

    placementSuggestionKeyRef.current = suggestionKey;
    updateAnswer(model.activeStep.id, 'vm_node_map', placementBoard.suggestedVmNodeMap || {});
  }, [clusterInstanceId, clusterId, currentDraft, model.activeStep, placementBoard]);

  const canInstallAll = !busy && model.mode === 'setup' && model.progress.remainingSteps > 0;

  const activeStepTitle = getDisplayStepTitle(model.activeStep);
  const activeStepPresentation = getStepPresentation(model.activeStep);
  const activeStepLinks = getStepLinkItems(model.activeStep);

  return (
    <div className="wizard-shell">
      <header className="wizard-topbar">
        <div className="wizard-brand-lockup">
          <a className="brand" href="#top" aria-label="Twinbox installation wizard">
            <span className="brand-mark" aria-hidden="true" />
            <span>
              Twinbox
              <strong>Web Installation Wizard</strong>
            </span>
          </a>
          <p className="wizard-kicker">Guided cluster bootstrap</p>
        </div>

        <div className="wizard-topbar-metrics" aria-label="Wizard summary">
          {topMetrics.map((metric) => (
            <div key={metric.label} className="wizard-metric">
              <span>{metric.label}</span>
              <strong>{metric.value}</strong>
            </div>
          ))}
        </div>

        <div className="wizard-topbar-actions">
          <button className="button button-secondary" type="button" onClick={handleExportAnswers}>
            Export all answers
          </button>
          <button className="button button-secondary" type="button" onClick={handleImportClick}>
            Import all answers
          </button>
          <button className="button button-primary" type="button" onClick={handleInstallAllSteps} disabled={!canInstallAll}>
            Install all steps
          </button>
        </div>
      </header>

      {(notice || error || visibleActiveJob?.id) && (
      <section className={`wizard-banner ${error ? 'is-error' : visibleActiveJob?.id ? 'is-notice' : 'is-notice'}`} aria-live="polite">
        <div>
          <strong>{error ? 'Something needs attention' : visibleActiveJob?.id ? 'Job in progress' : 'Status update'}</strong>
          <p>{error || notice || `Job ${visibleActiveJob.id} is ${visibleActiveJob.status.replace(/_/g, ' ')}`}</p>
        </div>
        <div className="wizard-banner-actions">
          {visibleActiveJob?.id && ['pending', 'running', 'cancel_requested'].includes(visibleActiveJob.status) ? (
            <button
              className="button button-danger"
              type="button"
              onClick={handleCancelActiveJob}
              disabled={visibleActiveJob.status === 'cancel_requested'}
            >
              {visibleActiveJob.status === 'cancel_requested' ? 'Stopping...' : 'Stop job'}
            </button>
          ) : null}
          {visibleActiveJob?.id ? (
            <span className="wizard-banner-job">Job {visibleActiveJob.id}</span>
          ) : null}
        </div>
      </section>
      )}

      <main className="wizard-layout">
        <aside className="wizard-rail" aria-label="Installation steps">
          <div className="wizard-rail-summary">
            <p className="eyebrow">Step rail</p>
            <h2>One step at a time</h2>
            <p>
              The wizard keeps the current step in focus and moves linearly from provisioning to bootstrap.
            </p>
            <div className="wizard-progress-bar" aria-hidden="true">
              <span style={{ width: `${model.progress.percent}%` }} />
            </div>
          </div>

          <nav className="wizard-step-list">
            {model.stepRail.map((step) => {
              const stepModel = model.steps.find((candidate) => candidate.id === step.id) || step;
              const stepTitle = getDisplayStepTitle(stepModel);

              return (
                <div
                  key={step.id}
                  className={`wizard-step ${step.isCurrent ? 'is-current' : ''} ${step.status === 'done' ? 'is-complete' : ''}`}
                >
                  <button
                    type="button"
                    className="wizard-step-select"
                    onClick={() => {
                      setSelectedStepId(step.id);
                      setNotice(`Viewing ${stepTitle}.`);
                    }}
                  >
                    <span className="wizard-step-index">{String(step.index).padStart(2, '0')}</span>
                    <span className="wizard-step-icon" aria-hidden="true">{step.icon || '🚀'}</span>
                    <span className="wizard-step-body">
                      <strong>{stepTitle}</strong>
                      <small>{formatState(step.status, 'Ready')}</small>
                    </span>
                  </button>

                  {step.status === 'done' ? (
                    <button
                      type="button"
                      className="button button-secondary wizard-step-reinstall"
                      onClick={() => handleReinstallStep(stepModel)}
                      disabled={busy || step.status === 'running'}
                    >
                      Reinstall
                    </button>
                  ) : null}
                </div>
              );
            })}
          </nav>
        </aside>

        <section className="wizard-workspace">
          <div className="wizard-workspace-header">
            <div className="wizard-workspace-copy">
              <p className="eyebrow">Twinbox installer</p>
              <div className="wizard-workspace-stepline">
                <span
                  className={`wizard-step-icon wizard-step-icon-large ${activeStepPresentation.iconArtworkUrl ? 'is-artwork' : ''}`}
                  aria-hidden="true"
                >
                  {activeStepPresentation.iconArtworkUrl ? (
                    <img
                      className="wizard-step-icon-artwork"
                      src={activeStepPresentation.iconArtworkUrl}
                      alt=""
                      loading="eager"
                      decoding="async"
                    />
                  ) : (
                    activeStepPresentation.icon
                  )}
                </span>
                <div className="wizard-workspace-stepline-copy">
                  <h1>{model.completion ? model.completion.title : activeStepTitle || 'Choose a setup step'}</h1>
                  <p className="wizard-intro wizard-step-pitch">
                    {model.completion
                      ? model.completion.summary
                      : model.activity.summary}
                  </p>
                  {activeStepLinks.length ? (
                    <div className="wizard-step-links wizard-step-links-top" aria-label="Step resources">
                      {activeStepLinks.map((item) => (
                        <a key={item.label} href={item.href} target="_blank" rel="noreferrer">
                          {item.label}
                        </a>
                      ))}
                    </div>
                  ) : null}
                </div>
              </div>
            </div>

            <div className="wizard-stage-meta">
              <div>
                <span>Stage</span>
                <strong>{model.activity.runtime.currentStage}</strong>
              </div>
              <div>
                <span>Last updated</span>
                <strong>{model.activity.runtime.lastUpdatedLabel}</strong>
              </div>
              <div>
                <span>Live state</span>
                <strong>{model.activity.runtime.runState}</strong>
              </div>
            </div>
          </div>

          {model.completion ? (
            <section className="wizard-finish-grid">
              <article className="wizard-card wizard-card-accent">
                <p className="eyebrow">Installation complete</p>
                <h2>{model.completion.stepTitle}</h2>
                <p>
                  {model.completion.summary}
                </p>
                <div className="wizard-card-actions">
                  <button className="button button-primary" type="button" onClick={handleExportAnswers}>
                    Export all answers
                  </button>
                  <button className="button button-secondary" type="button" onClick={handleImportClick}>
                    Import all answers
                  </button>
                </div>
              </article>

              <article className="wizard-card">
                <p className="eyebrow">Artifacts</p>
                <KeyValueList
                  items={model.activity.artifacts}
                  emptyLabel="No cluster artifacts have been published yet."
                />
              </article>
            </section>
          ) : (
            <div className="wizard-flow">
              <section className="wizard-card wizard-step-workspace">
                <p className="eyebrow">CURRENT STEP</p>
                <div className="wizard-step-context">
                  <p className="wizard-step-summary">{model.activity.explanation}</p>
                  <p className="wizard-step-sidehelp">{model.activity.sideHelp}</p>
                </div>

                {model.activeStep?.status === 'skipped' && (
                  <div className="skipped-banner">
                    <p>This step was skipped.</p>
                    <button type="button" onClick={() => handleUnskipAndExecute(model.activeStep)} disabled={busy}>
                      Run this step
                    </button>
                  </div>
                )}

                {provisionScaleSummary ? (
                  <section className="wizard-scale-panel" aria-label="Cluster scaling summary">
                    <div className="wizard-scale-head">
                      <div>
                        <p className="eyebrow">Cluster scale</p>
                        <h3>{provisionScaleSummary.scale_percent}% footprint</h3>
                      </div>
                      <span className="wizard-scale-pill">
                        {provisionScaleSummary.total_nodes} VMs
                      </span>
                    </div>

                    <div className="wizard-scale-grid">
                      <article>
                        <span>Control planes</span>
                        <strong>{provisionScaleSummary.controlplane_count}</strong>
                      </article>
                      <article>
                        <span>Workers</span>
                        <strong>{provisionScaleSummary.worker_count}</strong>
                      </article>
                      <article>
                        <span>CPU / VM</span>
                        <strong>{provisionScaleSummary.cpu_cores}</strong>
                      </article>
                      <article>
                        <span>Memory / VM</span>
                        <strong>{formatMemoryMb(provisionScaleSummary.memory_mb)}</strong>
                      </article>
                      <article>
                        <span>Disk / VM</span>
                        <strong>{provisionScaleSummary.disk_gb} GB</strong>
                      </article>
                      <article>
                        <span>Total CPU</span>
                        <strong>{provisionScaleSummary.total_cpu_cores}</strong>
                      </article>
                      <article>
                        <span>Total memory</span>
                        <strong>{formatMemoryMb(provisionScaleSummary.total_memory_mb)}</strong>
                      </article>
                      <article>
                        <span>Total disk</span>
                        <strong>{provisionScaleSummary.total_disk_gb} GB</strong>
                      </article>
                    </div>

                    {proxmoxResources?.summary ? (
                      <p className="wizard-scale-footnote">
                        Detected Proxmox free space: {formatMemoryMb(proxmoxResources.summary.freeMemoryMb)} RAM,
                        {' '}
                        {Math.round(proxmoxResources.summary.freeDiskGb)} GB disk,
                        {' '}
                        {Math.round(proxmoxResources.summary.freeCpuCores)} CPU cores.
                      </p>
                    ) : (
                      <p className="wizard-scale-footnote">
                        Cluster capacity data is unavailable right now, so the scale uses the step defaults.
                      </p>
                    )}
                  </section>
                ) : null}

                {model.activeStep?.id === 'provision-nodes' ? (
                  <>
                    <section className="wizard-input-block" aria-label="VM sizing">
                      <div className="wizard-input-block-head">
                        <div>
                          <p className="eyebrow">1. VM sizing</p>
                          <h3>Scale the cluster footprint</h3>
                        </div>
                        <p className="wizard-input-block-note">
                          The slider sets the starting footprint; the manual fields below stay editable.
                        </p>
                      </div>
                      <div className="wizard-input-grid">
                        {provisionInputGroups.vmInputs.map((input) => (
                          <InputField
                            key={input.id}
                            stepId={model.activeStep.id}
                            input={input}
                            value={currentDraft[input.id]}
                            onChange={(inputId, value) => updateAnswer(model.activeStep.id, inputId, value)}
                          />
                        ))}
                      </div>
                    </section>

                    <PlacementBoard
                      board={placementBoard}
                      draggingVmName={draggingVmName}
                      onDragStart={(event, vmName) => {
                        setDraggingVmName(vmName);
                        event.dataTransfer.effectAllowed = 'move';
                        event.dataTransfer.setData('text/plain', vmName);
                      }}
                      onDragEnd={() => setDraggingVmName('')}
                      onDropVm={(hostName) => {
                        if (draggingVmName) {
                          updatePlacement(draggingVmName, hostName);
                        }
                        setDraggingVmName('');
                      }}
                      onReset={resetPlacementToSuggested}
                    />

                    <section className="wizard-input-block is-network" aria-label="Network and addressing">
                      <div className="wizard-input-block-head">
                        <div>
                          <p className="eyebrow">3. Network and addressing</p>
                          <h3>Keep VM scale separate from networking</h3>
                        </div>
                        <p className="wizard-input-block-note">
                          The wizard probes the management VM network once, suggests free addresses for each VM, and then lets you edit them locally without another server check.
                        </p>
                      </div>

                      <dl className="wizard-network-summary">
                        <div>
                          <dt>Bridge</dt>
                          <dd>{currentDraft.bridge || 'vmbr0'}</dd>
                        </div>
                        <div>
                          <dt>VIP</dt>
                          <dd>{currentDraft.vip_ip || '192.168.1.50'}</dd>
                        </div>
                        <div>
                          <dt>Subnet</dt>
                          <dd>{provisionSubnet}</dd>
                        </div>
                        <div>
                          <dt>VMs</dt>
                          <dd>{provisionVmIpRows.length}</dd>
                        </div>
                        <div>
                          <dt>Gateway</dt>
                          <dd>{currentDraft.gateway_ip || '192.168.1.1'}</dd>
                        </div>
                        <div>
                          <dt>DNS</dt>
                          <dd>{currentDraft.dns_servers || '1.1.1.1, 8.8.8.8'}</dd>
                        </div>
                      </dl>

                      <div className="wizard-input-grid">
                        {provisionInputGroups.networkInputs.map((input) => (
                          <InputField
                            key={input.id}
                            stepId={model.activeStep.id}
                            input={input}
                            value={currentDraft[input.id]}
                            onChange={(inputId, value) => updateAnswer(model.activeStep.id, inputId, value)}
                          />
                        ))}
                      </div>

                      <div className="wizard-network-vm-list">
                        <div className="wizard-network-vm-list-head">
                          <div>
                            <p className="eyebrow">Per-VM IPs</p>
                            <h4>One address per VM, no fixed block</h4>
                          </div>
                          <p className="wizard-input-block-note">
                            Green means the suggested address was checked once. Amber means you changed it locally. Red means the value is invalid or duplicated.
                          </p>
                        </div>

                        <div className="wizard-network-vm-items">
                          {provisionVmIpRows.map((vm) => {
                            const currentVmIpMap = currentDraft.vm_ip_map && typeof currentDraft.vm_ip_map === 'object' && !Array.isArray(currentDraft.vm_ip_map)
                              ? currentDraft.vm_ip_map
                              : {};
                            const onVmIpChange = (value) => {
                              updateAnswer(model.activeStep.id, 'vm_ip_map', {
                                ...currentVmIpMap,
                                [vm.name]: value,
                              });
                            };

                            return (
                              <article key={vm.name} className={`wizard-network-vm-card is-${vm.status.tone}`}>
                                <header className="wizard-network-vm-card-head">
                                  <div>
                                    <strong>{vm.label}</strong>
                                    <span>VMID {vm.vmid} · {vm.assignedHostName || 'Unassigned'}</span>
                                  </div>
                                  <span className={`wizard-status-badge is-${vm.status.tone}`}>
                                    {vm.status.icon} {vm.status.label}
                                  </span>
                                </header>

                                <label className="wizard-field wizard-field-inline" htmlFor={`${model.activeStep.id}-${vm.name}-ip`}>
                                  <span className="wizard-field-label">IP address</span>
                                  <input
                                    id={`${model.activeStep.id}-${vm.name}-ip`}
                                    type="text"
                                    value={vm.value}
                                    onChange={(event) => onVmIpChange(event.target.value)}
                                    inputMode="decimal"
                                    placeholder={vm.suggestedIp || '192.168.1.60'}
                                  />
                                  <small>
                                    {vm.isSuggested
                                      ? 'This is the one-time free address suggestion from the server.'
                                      : 'This value is not rechecked against the server before install.'}
                                  </small>
                                </label>
                              </article>
                            );
                          })}
                        </div>

                        {provisionVmIpValidation.ok ? null : (
                          <p className="wizard-network-error">{provisionVmIpValidation.error}</p>
                        )}
                      </div>
                    </section>
                  </>
                ) : (
                  <div className="wizard-input-grid">
                    {(model.activeStep?.inputs || []).map((input) => (
                      <InputField
                        key={input.id}
                        stepId={model.activeStep.id}
                        input={input}
                        value={currentDraft[input.id]}
                        onChange={(inputId, value) => updateAnswer(model.activeStep.id, inputId, value)}
                      />
                    ))}
                    {(!model.activeStep?.inputs || model.activeStep.inputs.length === 0) && (
                      <p className="wizard-empty">This step does not need extra inputs. Review the output and continue.</p>
                    )}
                  </div>
                )}

                <div className="wizard-card-actions">
                  <button
                    className="button button-primary"
                    type="button"
                    onClick={handlePrimaryAction}
                    disabled={primaryActionDisabled}
                  >
                    {primaryActionLabel}
                  </button>
                  {(model.activeStep?.status === 'ready' || model.activeStep?.status === 'failed') && (
                    <button
                      type="button"
                      onClick={() => handleSkipStep(model.activeStep)}
                      className="skip-step-button"
                    >
                      Skip this step
                    </button>
                  )}
                  {model.activeStep?.status === 'done' ? (
                    <button
                      className="button button-secondary"
                      type="button"
                      onClick={() => handleReinstallStep(model.activeStep)}
                    >
                      Reinstall step
                    </button>
                  ) : null}
                  <button className="button button-secondary" type="button" onClick={handleImportClick}>
                    Import answers
                  </button>
                </div>

                <p className="wizard-helper">{primaryActionHelperText}</p>
              </section>

              <section
                ref={liveOutputRef}
                className={`wizard-card wizard-output-panel ${model.activity.runtime.isLive ? 'is-live' : ''}`}
              >
                <div className="wizard-output-header">
                  <div>
                    <p className="eyebrow">LIVE OUTPUT</p>
                    <h2>{model.activity.runtime.currentStage}</h2>
                  </div>
                  <span className={`wizard-status ${model.activity.runtime.isLive ? 'is-live' : ''}`}>
                    {model.activity.runtime.runState}
                  </span>
                </div>

                <div className="wizard-health-strip">
                  {model.healthBadges.map((badge) => (
                    <article key={badge.id} className={`wizard-badge tone-${badge.tone}`}>
                      <span>{badge.label}</span>
                      <strong>{badge.value}</strong>
                      <small>{badge.chip}</small>
                    </article>
                  ))}
                </div>

                <div className="wizard-output-stack">
                  <section>
                    <p className="wizard-stack-label">Artifacts</p>
                    <KeyValueList
                      items={model.activity.artifacts}
                      emptyLabel="Artifacts will appear after the first successful step."
                    />
                  </section>
                </div>

                <details className="technical-panel" open>
                  <summary>Technical details</summary>
                  <div className="technical-panel-body">
                    <div className="technical-panel-grid">
                      <div>
                        <p className="wizard-stack-label">Worker output</p>
                        <pre className="wizard-log-output">{model.activity.rawLogOutput}</pre>
                      </div>
                    </div>
                  </div>
                </details>
              </section>
            </div>
          )}
        </section>
      </main>

      <input
        ref={importInputRef}
        type="file"
        accept="application/json"
        className="wizard-file-input"
        onChange={handleImportFile}
      />
    </div>
  );
}

export default App;
