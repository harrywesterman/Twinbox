import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';

import './App.css';
import heroIllustrationUrl from './assets/hero-illustration.svg';
import {
  buildProvisionPlacementBoard,
  buildProvisionScaleSummary,
  buildScaledProvisionInputs,
  getProvisionNodeCount,
  formatMemoryMb,
} from './provision-scale.js';
import {
  buildProvisionVmIpMap,
  buildProvisionVmIpRows,
  isValidIpv4,
  validateProvisionVmIpRows,
} from './provision-network.js';
import {
  buildSuggestedProvisionInputs,
  mergeSuggestedProvisionDraft,
} from './provision-defaults.js';
import {
  buildWizardExportFilename,
  getMissionControlModel,
  getNextInstallableSetupStep,
  getWizardSteps,
  restoreUiState,
  serializeUiState,
  formatState,
} from './journey.js';
import { normalizeLogEntries } from './install-logs.js';
import { getQuestionSteps } from './question-flow.js';
import {
  isMissingClusterError,
  recoverMissingClusterState,
  recoverRecreatedClusterState,
  shouldResetRecreatedClusterDraft,
  refreshWizardSnapshot,
} from './catalog-refresh.js';

const POLL_INTERVAL_MS = 5000;
const PROVISION_STEP_ID = 'provision-nodes';

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

function buildProvisionQuestionDraft({
  step,
  answers = {},
  suggestionSnapshot = {},
  dirtyFields = new Set(),
}) {
  if (!step) {
    return {};
  }

  const baseDraft = buildInitialAnswers([step], answers)[step.id] || {};
  if (step.id !== PROVISION_STEP_ID) {
    return baseDraft;
  }

  return mergeSuggestedProvisionDraft({
    currentDraft: baseDraft,
    previousSuggested: buildSuggestedProvisionInputs(suggestionSnapshot),
    suggestionData: suggestionSnapshot,
    stepInputs: step.inputs || [],
    dirtyFields: Object.fromEntries([...dirtyFields].map((fieldId) => [fieldId, true])),
  });
}

function hasRequiredValue(input, value) {
  if (!input?.required) {
    return true;
  }

  if (input.type === 'boolean') {
    return typeof value === 'boolean';
  }

  if (input.type === 'integer') {
    return String(value ?? '').trim().length > 0 && Number.isFinite(Number(value));
  }

  return String(value ?? '').trim().length > 0;
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

function buildAdminDashboardUrl(cluster) {
  const rawDomain = String(cluster?.dns_domain || '').trim();
  if (!rawDomain) {
    return '';
  }

  const host = rawDomain
    .replace(/^https?:\/\//i, '')
    .replace(/^\/+/, '')
    .split('/')[0]
    .replace(/^\.+/, '');

  if (!host) {
    return '';
  }

  return `https://admin.${host}`;
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

function readStoredWizardState() {
  return restoreUiState(null);
}

function buildProvisionIpCheckTargets(vipIp, vmIpRows = []) {
  const targets = [];
  const seen = new Set();

  const addIp = (ip) => {
    const normalized = String(ip ?? '').trim();
    if (!normalized || seen.has(normalized)) {
      return;
    }

    seen.add(normalized);
    targets.push(normalized);
  };

  addIp(vipIp);
  for (const row of Array.isArray(vmIpRows) ? vmIpRows : []) {
    addIp(row?.value);
  }

  return targets;
}

function buildProvisionIpSuggestionsUrl(nodeCount) {
  const managementIp = typeof window !== 'undefined' ? String(window.location.hostname || '').trim() : '';
  const params = new URLSearchParams({
    node_count: String(nodeCount),
  });

  if (isValidIpv4(managementIp)) {
    params.set('management_ip', managementIp);
  }

  return {
    managementIp,
    url: `/api/ip-suggestions?${params.toString()}`,
  };
}

function summarizeProvisionIpCheckResults(results = []) {
  const entries = Array.isArray(results) ? results : [];
  const total = entries.length;
  const usedIps = entries
    .filter((entry) => entry?.in_use)
    .map((entry) => entry.ip)
    .filter(Boolean);

  if (total === 0) {
    return {
      label: 'No IP addresses were checked.',
      tone: 'neutral',
    };
  }

  if (usedIps.length === 0) {
    return {
      label: `Checked ${total} address${total === 1 ? '' : 'es'}. All are free.`,
      tone: 'success',
    };
  }

  return {
    label: `Checked ${total} address${total === 1 ? '' : 'es'}. ${usedIps.length} ${usedIps.length === 1 ? 'is' : 'are'} already in use: ${usedIps.slice(0, 3).join(', ')}${usedIps.length > 3 ? '…' : ''}`,
    tone: 'danger',
  };
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

function shouldReuseProvisionClusterSession(cluster) {
  return !['bootstrapped', 'provisioned'].includes(String(cluster?.status || ''));
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

function renderStepIcon(presentation, className) {
  const hasArtwork = Boolean(presentation?.iconArtworkUrl);

  return (
    <span
      className={`${className} ${hasArtwork ? 'is-artwork' : ''}`}
      aria-hidden="true"
    >
      {hasArtwork ? (
        <img
          className="wizard-step-icon-artwork"
          src={presentation.iconArtworkUrl}
          alt=""
          loading="eager"
          decoding="async"
        />
      ) : (
        presentation?.icon || '🚀'
      )}
    </span>
  );
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
    : '';
  const isDnsDomainField = stepId === 'choose-ingress-route' && input.id === 'dns_domain';

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
    if (stepId === 'choose-ingress-route' && input.id === 'ingress_route') {
      return (
        <div className="wizard-field wizard-field-choice-grid" aria-label={input.label}>
          <span className="wizard-field-label">{input.label}</span>
          <div className="wizard-choice-grid">
            {input.options.map((option, index) => {
              const checked = formatInputValue(input, value) === option.value;
              return (
                <button
                  key={option.value}
                  className={`wizard-choice-card ${checked ? 'is-selected' : ''}`}
                  type="button"
                  onClick={() => onChange(input.id, option.value)}
                >
                  <span className="wizard-choice-card-index">{index + 1}</span>
                  <strong>{option.label}</strong>
                  <small>{option.value === 'wiredoor'
                    ? 'Use your own Wiredoor bastion host.'
                    : option.value === 'cloudflare-tunnel'
                      ? 'No public IP or router forwarding.'
                      : option.value === 'metallb'
                        ? 'Use your LAN and router port forwarding.'
                        : 'Use Tailscale or Headscale to reach the cluster.'}</small>
                </button>
              );
            })}
          </div>
          <small>{helpText}</small>
          <em>{defaultLabel}</em>
        </div>
      );
    }

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

  if (stepId === 'provision-nodes' && (input.id === 'scale_percent' || input.id === 'worker_disk_percent')) {
    const numericValue = Number.isFinite(Number(value))
      ? Number(value)
      : Number.isFinite(Number(input.default))
        ? Number(input.default)
        : 90;

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

  const fieldClassName = isDnsDomainField
    ? 'wizard-field wizard-field-compact wizard-field-dns'
    : input.id === 'dns_servers'
      ? 'wizard-field wizard-field-compact'
      : 'wizard-field';

  return (
    <label className={fieldClassName} htmlFor={controlId}>
      <span className="wizard-field-label">{input.label}</span>
      {isDnsDomainField ? <p className="wizard-field-prelude">{helpText}</p> : null}
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
      {isDnsDomainField ? null : <small>{helpText}</small>}
      {isDnsDomainField || !defaultLabel ? null : <em>{defaultLabel}</em>}
    </label>
  );
}

const PROVISION_VM_INPUT_IDS = [
  'scale_percent',
  'worker_disk_percent',
  'controlplane_count',
  'worker_count',
  'cpu_cores',
  'memory_mb',
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
          <button className="button button-secondary" type="button" onClick={onReset}>
            Automatic placement
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
                host.assignments.map((vm) => {
                  if (vm.isFixed) {
                    return (
                      <div
                        key={vm.id || vm.name}
                        className="wizard-vm-card is-fixed"
                        role="group"
                        aria-label={`${vm.label} on ${host.name}`}
                      >
                        <span className="wizard-vm-card-title">{vm.label}</span>
                        <strong>{vm.name}</strong>
                        <small>
                          {vm.vmid != null ? `VMID ${vm.vmid}` : 'VMID —'}
                          {vm.cpu ? ` | ${vm.cpu} CPU` : ''}
                          {vm.memory_mb != null ? ` | ${formatMemoryMb(vm.memory_mb)} RAM` : ''}
                          {vm.disk_gb != null ? ` | ${vm.disk_gb} GB disk` : ''}
                        </small>
                        <em>Fixed on this host and included in the resource budget.</em>
                      </div>
                    );
                  }

                  return (
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
                            ? 'Suggested here to balance CPU, memory, and disk across the cluster.'
                            : 'This VM is not assigned yet.'}
                      </em>
                    </button>
                  );
                })
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

function hasPlacementAssignments(vmNodeMap) {
  if (!vmNodeMap || typeof vmNodeMap !== 'object' || Array.isArray(vmNodeMap)) {
    return false;
  }

  return Object.values(vmNodeMap).some((hostName) => String(hostName || '').trim().length > 0);
}

function buildPlacementSuggestionKey(board) {
  if (!board?.hostCards?.length || !board?.vmPlan?.length) {
    return '';
  }

  const hostKey = board.hostCards.map((host) => host.id).join(',');
  const vmKey = board.vmPlan.map((vm) => vm.id).join(',');
  const suggestionKey = Object.entries(board.suggestedVmNodeMap || {})
    .sort(([leftVmName], [rightVmName]) => leftVmName.localeCompare(rightVmName))
    .map(([vmName, hostName]) => `${vmName}:${hostName}`)
    .join('|');

  return `${hostKey}::${vmKey}::${suggestionKey}`;
}

const INGRESS_ROUTE_LABELS = {
  wiredoor: '1. Wiredoor',
  'cloudflare-tunnel': '2. Cloudflare Tunnel',
  metallb: '3. MetalLB',
  tailscale: '4. Tailscale',
};

const WIZARD_GUIDES = {
  'provision-nodes': {
    eyebrow: 'Step 1',
    title: 'Create the Talos cluster',
    intro: 'This is the point where Twinbox actually creates the Kubernetes cluster. You choose how many machines to make, how large they should be, and which network values Talos should use.',
    checklist: [
      'Pick the cluster name you want to see in Twinbox.',
      'Choose the number of control planes and worker nodes.',
      'Confirm the VM size, gateway, and DNS values.',
      'Review the placement board before you continue.',
    ],
    screenshotTitle: 'What this step looks like',
    screenshotLines: [
      'Talos cluster sizing',
      'Control plane and worker counts',
      'Network values and VM placement',
    ],
    helpLink: {
      label: 'Talos documentation',
      href: 'https://www.talos.dev/',
    },
  },
  'choose-ingress-route': {
    eyebrow: 'Routing',
    title: 'Choose how users will reach the cluster',
    intro: 'Pick the ingress route that matches your network. The wizard will only show the follow-up questions for the path you choose.',
    checklist: [
      'Read the short explanation for each route.',
      'Pick option 1, 2, 3, or 4.',
      'Continue only with the follow-up questions for that route.',
    ],
    screenshotTitle: 'Route choice',
    screenshotLines: [
      '1. Wiredoor',
      '2. Cloudflare Tunnel',
      '3. MetalLB',
      '4. Tailscale',
    ],
    helpLink: {
      label: 'Wizard guide',
      href: 'https://github.com/harrywesterman/twinbox/blob/main/docs/wizard-guide.md',
    },
  },
  'provision-wiredoor-bastion': {
    eyebrow: 'Wiredoor setup',
    title: 'Create the Wiredoor bastion host',
    intro: 'Twinbox needs a Hetzner Cloud VM that will run Wiredoor. This step asks for the Hetzner token and a few placement values, then it provisions the bastion automatically.',
    checklist: [
      'Create a Hetzner Cloud project.',
      'Generate a Read & Write API token.',
      'Choose the location and server type.',
      'Paste your domain name and optional SSH key.',
    ],
    screenshotTitle: 'How to get the token',
    screenshotLines: [
      'Open Hetzner Cloud',
      'Go to Security → API Tokens',
      'Create a Read & Write token',
      'Copy the token once and save it safely',
    ],
    helpLink: {
      label: 'Hetzner Cloud',
      href: 'https://console.hetzner.cloud/',
    },
  },
  'configure-wiredoor-ingress': {
    eyebrow: 'Wiredoor setup',
    title: 'Connect Twinbox to Wiredoor',
    intro: 'This step connects your cluster to the bastion host you just created. You need the Wiredoor server URL, the API token, and an optional node name.',
    checklist: [
      'Open the Wiredoor admin screen.',
      'Copy the server URL exactly as shown.',
      'Create or reuse an API token.',
      'Leave the node name blank if you want the default.',
    ],
    screenshotTitle: 'Where to find it',
    screenshotLines: [
      'Wiredoor server URL',
      'API token field',
      'Optional node name',
      'All values are pasted into Twinbox once',
    ],
    helpLink: {
      label: 'Wiredoor',
      href: 'https://wiredoor.net/',
    },
  },
  'configure-cloudflare-tunnel': {
    eyebrow: 'Cloudflare setup',
    title: 'Prepare the Cloudflare Tunnel connection',
    intro: 'Use one custom Cloudflare API token that can edit both the tunnel and the DNS zone. Twinbox also needs your account ID and zone ID.',
    checklist: [
      'Open the Cloudflare dashboard.',
      'Create one custom token with the right permissions.',
      'Copy the account ID and zone ID from the dashboard.',
      'Paste those values into Twinbox.',
    ],
    screenshotTitle: 'Create one custom token',
    screenshotLines: [
      'My Profile → API Tokens',
      'Create Custom Token',
      'Add Tunnel Edit and DNS Edit permissions',
      'Copy the Account ID and Zone ID',
    ],
    helpLink: {
      label: 'Cloudflare API tokens',
      href: 'https://dash.cloudflare.com/profile/api-tokens',
    },
  },
  'configure-cloudflare-dns': {
    eyebrow: 'Cloudflare setup',
    title: 'Create the DNS records in Cloudflare',
    intro: 'This step creates the DNS records that point your public hostnames to the Wiredoor bastion host. You only need a Cloudflare API token and your domain name.',
    checklist: [
      'Create a Cloudflare token with DNS edit permission.',
      'Pick the domain you already own or added to Cloudflare.',
      'Paste the token and domain name into Twinbox.',
      'Let Twinbox create the A and wildcard records for you.',
    ],
    screenshotTitle: 'DNS token checklist',
    screenshotLines: [
      'Zone DNS Edit permission',
      'Your domain name',
      'Twinbox writes the required records automatically',
      'No manual zone editing after this',
    ],
    helpLink: {
      label: 'Cloudflare DNS',
      href: 'https://developers.cloudflare.com/dns/',
    },
  },
  'configure-metallb-ingress': {
    eyebrow: 'MetalLB setup',
    title: 'Prepare the local network exposure',
    intro: 'MetalLB needs an IP range, a public host name, and optional DynDNS details if your home IP changes. Twinbox uses those values to make the cluster reachable.',
    checklist: [
      'Reserve a free IP range on your local network.',
      'Decide which public host name should point to the router.',
      'Add DynDNS details only if your IP address changes over time.',
      'Forward ports 80 and 443 on your router.',
    ],
    screenshotTitle: 'What to prepare',
    screenshotLines: [
      'IP range for load balancers',
      'Router public hostname',
      'Optional DynDNS token',
      'Port forwarding on the router',
    ],
    helpLink: {
      label: 'MetalLB',
      href: 'https://metallb.universe.tf/',
    },
  },
  'configure-tailscale-ingress': {
    eyebrow: 'Tailscale setup',
    title: 'Connect the cluster to your tailnet',
    intro: 'This step joins the cluster to Tailscale or Headscale. You need an auth key, and optionally a tag plus Headscale details.',
    checklist: [
      'Create a Tailscale auth key.',
      'Add an ACL tag if you use one.',
      'Only fill in Headscale if you self-host it.',
      'Copy the values into Twinbox once.',
    ],
    screenshotTitle: 'Tailscale admin screen',
    screenshotLines: [
      'Auth keys page',
      'Optional tag field',
      'Headscale URL and API key only when self-hosted',
      'No public port forwarding required',
    ],
    helpLink: {
      label: 'Tailscale auth keys',
      href: 'https://login.tailscale.com/admin/settings/keys',
    },
  },
  'create-users-and-groups': {
    eyebrow: 'Identity',
    title: 'Create the first user account',
    intro: 'Twinbox creates the first Authentik user and adds it to the admin group. This is the account you will use to log in to the platform later.',
    checklist: [
      'Enter the full name you want to see in the UI.',
      'Choose a login name you will remember.',
      'Add an email address if you want recovery support.',
    ],
    screenshotTitle: 'User account details',
    screenshotLines: [
      'Full name',
      'Login name',
      'Optional email address',
      'This becomes the first admin account',
    ],
    helpLink: {
      label: 'Authentik',
      href: 'https://goauthentik.io/',
    },
  },
};

function getWizardGuide(stepId) {
  return WIZARD_GUIDES[stepId] || {
    eyebrow: 'Step details',
    title: 'Review this step carefully',
    intro: 'Twinbox will use the values from this page to continue the install.',
    checklist: [
      'Read the short explanation.',
      'Fill in the fields on the page.',
      'Continue when the values are correct.',
    ],
    screenshotTitle: 'Example layout',
    screenshotLines: [
      'Guidance on the left',
      'Fields on the right',
      'One clear action at the bottom',
    ],
  };
}

function renderTopBar({ onImportClick, showImportButton = true } = {}) {
  return (
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
      <div className="wizard-topbar-actions">
        {showImportButton ? (
          <button className="button button-secondary" type="button" onClick={onImportClick}>
            Load saved answers
          </button>
        ) : null}
      </div>
    </header>
  );
}

function App() {
  const storedWizardState = useMemo(() => readStoredWizardState(), []);
  const importInputRef = useRef(null);
  const liveOutputRef = useRef(null);
  const liveLogViewportRef = useRef(null);
  const liveLogAutoScrollRef = useRef(true);
  const busyRef = useRef(false);
  const hasStartedRef = useRef(false);
  const clusterIdRef = useRef('');
  const clusterCreatedAtRef = useRef('');
  const clusterInstanceIdRef = useRef('');
  const selectedStepIdRef = useRef('');
  const answersRef = useRef({});
  const hydratedRef = useRef(false);
  const provisionDirtyFieldsRef = useRef(new Set());
  const provisionSuggestionKeyRef = useRef('');
  const provisionSuggestionSnapshotRef = useRef({});
  const installLogsByStepRef = useRef({});

  const [catalog, setCatalog] = useState({ categories: [], errors: [] });
  const [health, setHealth] = useState({ ok: false });
  const [selectedStepId, setSelectedStepId] = useState(storedWizardState.selectedStepId || '');
  const [answers, setAnswers] = useState(storedWizardState.answers || {});
  const [clusterId, setClusterId] = useState(storedWizardState.clusterId || '');
  const [clusterCreatedAt, setClusterCreatedAt] = useState(storedWizardState.clusterCreatedAt || '');
  const [clusterInstanceId, setClusterInstanceId] = useState(storedWizardState.clusterInstanceId || '');
  const [cluster, setCluster] = useState(null);
  const [proxmoxResources, setProxmoxResources] = useState(null);
  const [logs, setLogs] = useState([]);
  const [draggingVmName, setDraggingVmName] = useState('');
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState('');
  const [error, setError] = useState('');
  const [activeJob, setActiveJob] = useState(null);
  const [provisionSuggestionsReadyState, setProvisionSuggestionsReadyState] = useState(false);
  const [provisionSuggestionRevision, setProvisionSuggestionRevision] = useState(0);
  const [provisionIpCheckState, setProvisionIpCheckState] = useState({
    checkedAt: '',
    results: {},
  });
  const [provisionIpChecking, setProvisionIpChecking] = useState(false);
  const [provisionIpSuggestionsLoading, setProvisionIpSuggestionsLoading] = useState(false);
  const [hasStarted, setHasStarted] = useState(Boolean(
    storedWizardState.selectedStepId
    || storedWizardState.clusterId
    || storedWizardState.clusterCreatedAt
    || storedWizardState.clusterInstanceId
    || (storedWizardState.answers && Object.keys(storedWizardState.answers).length > 0),
  ));
  const [wizardPhase, setWizardPhase] = useState(() => {
    const storedQuestionStepIds = new Set(getQuestionSteps(storedWizardState.answers).map((step) => step.id));
    if (storedWizardState.selectedStepId && !storedQuestionStepIds.has(storedWizardState.selectedStepId)) {
      return 'install';
    }

    return 'questions';
  });
  const [isBootstrapping, setIsBootstrapping] = useState(true);
  const placementSuggestionKeyRef = useRef('');
  const wizardPhaseRef = useRef('questions');

  useEffect(() => {
    hydratedRef.current = true;
  }, []);

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

  const questionSteps = useMemo(() => getQuestionSteps(answers), [answers]);
  const setupSteps = useMemo(() => getWizardSteps(catalog, answers), [catalog, answers]);
  const initialAnswers = useMemo(() => buildInitialAnswers([...setupSteps, ...questionSteps], answers), [questionSteps, setupSteps, answers]);
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
  const adminDashboardUrl = useMemo(() => buildAdminDashboardUrl(cluster), [cluster]);
  const isInstallPhase = hasStarted && wizardPhase === 'install' && !model.completion;
  const questionStepIndex = questionSteps.findIndex((step) => step.id === selectedStepId);
  const currentQuestionStep = questionStepIndex >= 0 ? questionSteps[questionStepIndex] : (questionSteps[0] || null);
  const previousQuestionStep = questionStepIndex > 0 ? questionSteps[questionStepIndex - 1] : null;
  const nextQuestionStep = questionStepIndex >= 0 && questionStepIndex < questionSteps.length - 1
    ? questionSteps[questionStepIndex + 1]
    : null;
  const installStepIndex = setupSteps.findIndex((step) => step.id === selectedStepId);
  const safeInstallStepIndex = installStepIndex >= 0 ? installStepIndex : 0;
  const currentInstallStep = installStepIndex >= 0 ? setupSteps[installStepIndex] : (setupSteps[0] || null);
  const previousInstallStep = installStepIndex > 0 ? setupSteps[installStepIndex - 1] : null;
  const nextInstallStep = installStepIndex >= 0 && installStepIndex < setupSteps.length - 1
    ? setupSteps[installStepIndex + 1]
    : null;
  const isQuestionPhase = hasStarted && wizardPhase === 'questions';
  const currentStep = isQuestionPhase ? currentQuestionStep : (currentInstallStep || model.activeStep);

  function setInstallStepLogs(stepId, lines = []) {
    if (!stepId) {
      return;
    }

    const nextLines = normalizeLogEntries(lines);
    installLogsByStepRef.current = {
      ...installLogsByStepRef.current,
      [stepId]: nextLines,
    };
    setLogs(nextLines);
  }

  function clearInstallStepLogs() {
    installLogsByStepRef.current = {};
    setLogs([]);
  }

  function selectInstallStep(stepId) {
    if (!stepId) {
      return;
    }

    selectedStepIdRef.current = stepId;
    setSelectedStepId(stepId);
    setLogs(normalizeLogEntries(installLogsByStepRef.current[stepId] || []));
  }

  useEffect(() => {
    if (!hasStarted || wizardPhase !== 'questions') {
      return;
    }

    const firstQuestionId = questionSteps[0]?.id || '';
    if (!firstQuestionId) {
      return;
    }

    if (!selectedStepId) {
      setSelectedStepId(firstQuestionId);
    }
  }, [hasStarted, wizardPhase, questionSteps, selectedStepId]);

  useEffect(() => {
    if (!hasStarted || wizardPhase !== 'install') {
      return;
    }

    const firstInstallStepId = setupSteps[0]?.id || '';
    if (!firstInstallStepId) {
      return;
    }

    if (!selectedStepId) {
      setSelectedStepId(firstInstallStepId);
    }
  }, [hasStarted, wizardPhase, setupSteps, selectedStepId]);

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
          setInstallStepLogs,
          setActiveJob,
          setAnswers,
          setNotice,
          setError,
          setProvisionSuggestionsReady: setProvisionSuggestionsReadyState,
          allowAutoSelectStep: hasStartedRef.current && wizardPhaseRef.current === 'install',
        });
      } catch (refreshError) {
        if (!cancelled) {
          setError(refreshError instanceof Error ? refreshError.message : 'Failed to refresh wizard state');
        }
      }
    };

    (async () => {
      try {
        await refreshSnapshot();
      } finally {
        if (!cancelled) {
          setIsBootstrapping(false);
        }
      }
    })();
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
            setCluster,
            setLogs,
            clearInstallLogs: clearInstallStepLogs,
            setActiveJob,
            setError,
            setNotice,
              provisionDirtyFieldsRef,
              provisionSuggestionKeyRef,
              provisionSuggestionSnapshotRef,
              placementSuggestionKeyRef,
              setProvisionSuggestionsReady: setProvisionSuggestionsReadyState,
            });

            const nextQuestionStepId = getQuestionSteps(answersRef.current)[0]?.id || 'provision-nodes';
            setWizardPhase('questions');
            setSelectedStepId(nextQuestionStepId);
            selectedStepIdRef.current = nextQuestionStepId;
            clearInstallStepLogs();
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
            setCluster,
            setLogs,
            clearInstallLogs: clearInstallStepLogs,
            setActiveJob,
            setError,
            setNotice,
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

  useEffect(() => {
    hasStartedRef.current = hasStarted;
  }, [hasStarted]);

  useEffect(() => {
    wizardPhaseRef.current = wizardPhase;
  }, [wizardPhase]);

  useEffect(() => {
    const viewport = liveLogViewportRef.current;
    if (!viewport) {
      return undefined;
    }

    const handleScroll = () => {
      const distanceFromBottom = viewport.scrollHeight - viewport.scrollTop - viewport.clientHeight;
      if (distanceFromBottom < 72) {
        liveLogAutoScrollRef.current = true;
      } else if (viewport.scrollTop > 0) {
        liveLogAutoScrollRef.current = false;
      }
    };

    viewport.addEventListener('scroll', handleScroll, { passive: true });

    return () => {
      viewport.removeEventListener('scroll', handleScroll);
    };
  }, []);

  useEffect(() => {
    if (!isInstallPhase) {
      return;
    }

    liveLogAutoScrollRef.current = true;
  }, [isInstallPhase, currentStep?.id]);

  useEffect(() => {
    if (!isInstallPhase || !currentStep?.id) {
      return;
    }

    const cachedLogs = installLogsByStepRef.current[currentStep.id];
    setLogs(normalizeLogEntries(cachedLogs || []));
  }, [currentStep?.id, isInstallPhase]);

  useLayoutEffect(() => {
    if (!liveLogAutoScrollRef.current) {
      return;
    }

    const viewport = liveLogViewportRef.current;
    if (!viewport) {
      return;
    }

    viewport.scrollTop = viewport.scrollHeight;
    const raf = window.requestAnimationFrame(() => {
      viewport.scrollTop = viewport.scrollHeight;
    });

    return () => window.cancelAnimationFrame(raf);
  }, [logs, activeJob?.id, currentStep?.id, isInstallPhase, model?.activity?.runtime?.currentStage]);

  async function pollJob(jobId, stepId) {
    let latestJob = null;
    let latestLogs = [];

    for (;;) {
      const [jobData, logsData] = await Promise.all([
        requestJson(`/api/jobs/${encodeURIComponent(jobId)}`),
        requestJson(`/api/jobs/${encodeURIComponent(jobId)}/logs`),
      ]);

      latestJob = jobData;
      latestLogs = logsData?.lines || [];
      if (stepId && latestLogs.length > 0) {
        setInstallStepLogs(stepId, latestLogs);
      }

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

  function updateProvisionDraft(stepId, updater) {
    setAnswers((current) => {
      const currentStepDraft = current[stepId] || {};
      const nextDraft = typeof updater === 'function'
        ? updater(currentStepDraft)
        : { ...currentStepDraft, ...(updater || {}) };

      return {
        ...current,
        [stepId]: nextDraft,
      };
    });
  }

  function clearProvisionDirtyFields(fieldIds = []) {
    for (const fieldId of fieldIds) {
      provisionDirtyFieldsRef.current.delete(fieldId);
    }
  }

  async function applyProvisionVmSizeHelp() {
    if (currentStep?.id !== 'provision-nodes') {
      return;
    }

    try {
      const draft = answersRef.current?.[currentStep.id] || {};
      const suggested = buildScaledProvisionInputs(
        draft.scale_percent ?? 90,
        currentStep.inputs || [],
        draft,
        new Set(),
        proxmoxResources,
      );

      updateProvisionDraft(currentStep.id, {
        controlplane_count: suggested.controlplane_count,
        worker_count: suggested.worker_count,
        cpu_cores: suggested.cpu_cores,
        memory_mb: suggested.memory_mb,
      });
      clearProvisionDirtyFields(['controlplane_count', 'worker_count', 'cpu_cores', 'memory_mb']);
      setNotice('Filled the VM sizing defaults from the current cluster scale.');
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Failed to fill VM sizing defaults.';
      setError(message);
      setNotice(message);
    }
  }

  async function applyProvisionPlacementHelp() {
    if (currentStep?.id !== 'provision-nodes') {
      return;
    }

    try {
      const draft = answersRef.current?.[currentStep.id] || {};
      const board = buildProvisionPlacementBoard(currentStep.inputs || [], draft, proxmoxResources);
      if (!board?.hostCards?.length) {
        throw new Error('No Proxmox host resources are available yet.');
      }

      const suggestedMap = board?.suggestedVmNodeMap || {};
      const suggestedSizeMap = board?.suggestedVmSizeMap || {};

      updateProvisionDraft(currentStep.id, {
        vm_node_map: suggestedMap,
        vm_size_map: suggestedSizeMap,
      });
      setNotice('Filled the placement board from the current Proxmox host resources.');
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Failed to fill placement defaults.';
      setError(message);
      setNotice(message);
    }
  }

  async function applyProvisionIpHelp() {
    if (currentStep?.id !== 'provision-nodes' || busyRef.current || provisionIpSuggestionsLoading) {
      return;
    }

    setProvisionIpSuggestionsLoading(true);
    setError('');
    setNotice('Checking the local subnet for free IP addresses. Please wait while Twinbox fills them in automatically.');

    try {
      const draft = answersRef.current?.[currentStep.id] || {};
      const nodeCount = getProvisionNodeCount(currentStep.inputs || [], draft);
      const { managementIp, url } = buildProvisionIpSuggestionsUrl(nodeCount);
      const suggestionKey = `${managementIp || 'unknown'}:${nodeCount}`;
      const suggestionData = await requestJson(url);
      const board = buildProvisionPlacementBoard(currentStep.inputs || [], draft, proxmoxResources);
      const vmIpRows = buildProvisionVmIpRows(board?.vmPlan || [], draft, suggestionData, {});

      provisionSuggestionKeyRef.current = suggestionKey;
      provisionSuggestionSnapshotRef.current = suggestionData;
      setProvisionSuggestionRevision((current) => current + 1);

      updateProvisionDraft(currentStep.id, {
        vip_ip: suggestionData.vip_ip || draft.vip_ip,
        node_prefix_length: suggestionData.node_prefix_length ?? draft.node_prefix_length,
        gateway_ip: suggestionData.gateway_ip || draft.gateway_ip,
        dns_servers: Array.isArray(suggestionData.dns_servers)
          ? suggestionData.dns_servers.join(',')
          : (suggestionData.dns_servers || draft.dns_servers),
        dns_domain: suggestionData.dns_domain ?? draft.dns_domain,
        vm_ip_map: buildProvisionVmIpMap(vmIpRows),
      });
      setNotice('Twinbox checked the subnet and filled the free IP defaults automatically.');
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Failed to fill free IP defaults.';
      setError(message);
      setNotice(message);
    } finally {
      setProvisionIpSuggestionsLoading(false);
    }
  }

  async function executeStep(step, clusterIdOverride = clusterIdRef.current, options = {}) {
    const { manageBusy = true } = options;
    const currentStepDraft = answersRef.current?.[step.id] || {};
    const draft = currentStepDraft;
    const body = {
      inputs: buildPayloadInputs(step, draft),
    };

    if (step.id === 'provision-nodes') {
      const ipAvailability = await fetchProvisionIpAvailability();
      if (ipAvailability.checkedAt) {
        setProvisionIpCheckState({
          checkedAt: ipAvailability.checkedAt,
          results: ipAvailability.results || {},
        });
      }

      if (!ipAvailability.ok) {
        const message = ipAvailability.error || ipAvailability.summary?.label || 'IP addresses must be free before starting step 1.';
        setError(message);
        setNotice(message);
        return { ok: false, error: message };
      }
    }

    if (step.id === 'provision-nodes') {
      if (clusterInstanceIdRef.current && shouldReuseProvisionClusterSession(cluster)) {
        body.cluster_instance_id = clusterInstanceIdRef.current;
      }
    } else if (clusterInstanceIdRef.current) {
      body.cluster_instance_id = clusterInstanceIdRef.current;
    }

    if (step.id !== 'provision-nodes' && clusterIdOverride) {
      body.cluster_id = clusterIdOverride;
    }

    if (step.id === 'provision-nodes') {
      const placement = buildProvisionPlacementBoard(step.inputs || [], draft, proxmoxResources);
      const vmIpRows = buildProvisionVmIpRows(placement.vmPlan, draft, provisionSuggestionSnapshotRef.current);
      const vmIpValidation = validateProvisionVmIpRows(vmIpRows);
      if (!vmIpValidation.ok) {
        const message = vmIpValidation.error || 'VM IP addresses must be valid before starting step 1.';
        setError(message);
        setNotice(message);
        return { ok: false, error: message };
      }

      const explicitPlacementMap = draft.vm_node_map && typeof draft.vm_node_map === 'object'
        ? draft.vm_node_map
        : {};
      const hasExplicitPlacement = hasPlacementAssignments(explicitPlacementMap);
      body.vm_node_map = hasExplicitPlacement
        ? placement.vmNodeMap
        : placement.suggestedVmNodeMap;
      body.vm_size_map = hasExplicitPlacement
        ? placement.vmSizeMap
        : placement.suggestedVmSizeMap;
      body.vm_ip_map = buildProvisionVmIpMap(vmIpRows);
    }

    if (manageBusy) {
      setBusy(true);
    }
    setError('');
    setNotice(`Queued ${step.title}.`);
    selectInstallStep(step.id);
    setActiveJob({ id: null, stepId: step.id, status: 'starting' });
    setInstallStepLogs(step.id, []);

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

      const terminal = await pollJob(response.job_id, step.id);
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
        const currentInstallIndex = setupSteps.findIndex((candidate) => candidate.id === step.id);
        const nextInstallStep = currentInstallIndex >= 0 ? setupSteps[currentInstallIndex + 1] : null;
        if (nextInstallStep?.id) {
          selectInstallStep(nextInstallStep.id);
        }
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
        setInstallStepLogs,
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
    if (!isQuestionPhase || !currentStep || busyRef.current) {
      return;
    }

    if (currentStep?.id === 'provision-nodes' && !provisionStepValid) {
      const message = provisionVmIpValidation.error || 'Fill in the Talos IP addresses before continuing.';
      setNotice(message);
      return;
    }

    if (isQuestionPhase) {
      if (nextQuestionStep) {
        setSelectedStepId(nextQuestionStep.id);
        return;
      }

      const firstInstallStepId = setupSteps[0]?.id || 'provision-nodes';
      setWizardPhase('install');
      setSelectedStepId(firstInstallStepId);
      setNotice('Review each install step, run them one by one, or use Install all.');
      return;
    }
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
        setInstallStepLogs,
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

  async function handleUnskipAndExecute(step, options = {}) {
    const { manageBusy = true } = options;
    if (!step || (manageBusy && busy) || step.status !== 'skipped') {
      return;
    }

    if (manageBusy) {
      setBusy(true);
    }
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
        setInstallStepLogs,
        setActiveJob,
        setAnswers,
        setNotice,
        setError,
        setProvisionSuggestionsReady: setProvisionSuggestionsReadyState,
      });
      const refreshedStep = { ...step, status: 'ready' };
      return await executeStep(refreshedStep, clusterIdRef.current, { manageBusy });
    } catch (err) {
      const message = err instanceof Error ? err.message : `Failed to run ${step.title}`;
      setError(message);
      return { ok: false, error: message };
    } finally {
      if (manageBusy) {
        setBusy(false);
      }
    }
  }

  async function handleInstallCurrentStep(step) {
    if (!step || busyRef.current) {
      return;
    }

    if (step.id === 'provision-nodes' && !provisionStepValid) {
      const message = provisionVmIpValidation.error || 'Fill in the Talos IP addresses before starting step 1.';
      setNotice(message);
      return;
    }

    if (step.status === 'locked') {
      setNotice(`Run the earlier steps first before installing ${step.title}.`);
      return;
    }

    if (step.status === 'skipped') {
      await handleUnskipAndExecute(step);
      return;
    }

    await executeStep(step);
  }

  async function handleInstallAllSteps(fromStepId = selectedStepId) {
    if (!setupSteps.length || busyRef.current) {
      return;
    }

    const firstPendingStep = getNextInstallableSetupStep(catalog, answersRef.current, fromStepId);
    if (!firstPendingStep) {
      setNotice('Every remaining setup step is already complete.');
      return;
    }

    setBusy(true);
    setError('');
    setNotice('Installing all remaining setup steps in order.');
    setWizardPhase('install');

    try {
      let nextClusterId = clusterIdRef.current;
      let currentCatalogData = catalog;
      const processedStepIds = new Set();
      let cursorStepId = fromStepId;

      while (true) {
        const currentStep = getNextInstallableSetupStep(
          currentCatalogData,
          answersRef.current,
          cursorStepId,
          processedStepIds,
        );

        if (!currentStep) {
          break;
        }

        setSelectedStepId(currentStep.id);

        if (currentStep.status === 'locked') {
          throw new Error(`${currentStep.title} is locked until its dependencies are complete.`);
        }

        const result = currentStep.status === 'skipped'
          ? await handleUnskipAndExecute(currentStep, { manageBusy: false })
          : await executeStep(currentStep, nextClusterId, { manageBusy: false });

        processedStepIds.add(currentStep.id);
        nextClusterId = result.clusterId || nextClusterId;

        if (!result.ok) {
          break;
        }

        currentCatalogData = result.catalog || currentCatalogData;
        cursorStepId = currentStep.id;
      }
    } finally {
      setBusy(false);
      setActiveJob(null);
    }
  }

  function updateAnswer(stepId, inputId, value) {
    if (stepId === 'provision-nodes' && inputId !== 'scale_percent') {
      provisionDirtyFieldsRef.current.add(inputId);
    }

    setAnswers((current) => {
      const currentStep = current[stepId] || {};
      const nextStep = {
        ...currentStep,
        [inputId]: value,
      };

      if (stepId === 'provision-nodes' && inputId === 'scale_percent') {
        const currentScale = Number.isFinite(Number(value)) ? Number(value) : 90;
        return {
          ...current,
          [stepId]: buildScaledProvisionInputs(
            currentScale,
            currentStep?.inputs || [],
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
    if (!vmName || !hostName || currentStep?.id !== 'provision-nodes') {
      return;
    }

    const currentMap = currentDraft.vm_node_map && typeof currentDraft.vm_node_map === 'object'
      ? currentDraft.vm_node_map
      : {};

    updateAnswer(currentStep.id, 'vm_node_map', {
      ...currentMap,
      [vmName]: hostName,
    });
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

  async function fetchProvisionIpAvailability() {
    if (currentStep?.id !== 'provision-nodes') {
      return {
        ok: false,
        error: 'IP checks are only available on Deploy Talos Cluster.',
      };
    }

    if (!provisionVmIpRows.length) {
      return {
        ok: false,
        error: 'Enter the Talos IP values before checking availability.',
      };
    }

    const vipIp = String(currentDraft.vip_ip || '').trim();
    if (vipIp && !isValidIpv4(vipIp)) {
      return {
        ok: false,
        error: 'VIP IP must be a valid IPv4 address.',
      };
    }

    const invalidVmRow = provisionVmIpRows.find((row) => !row.isValid);
    if (invalidVmRow) {
      return {
        ok: false,
        error: provisionVmIpValidation.error || `Invalid IP address for ${invalidVmRow.label || invalidVmRow.name}`,
      };
    }

    const targets = buildProvisionIpCheckTargets(vipIp, provisionVmIpRows);
    if (!targets.length) {
      return {
        ok: false,
        error: 'Enter at least one IP address before checking them.',
      };
    }

    const response = await requestJson('/api/ip-availability', {
      method: 'POST',
      body: JSON.stringify({ ips: targets }),
    });

    const results = Array.isArray(response?.results) ? response.results : [];
    const availabilityResults = results.reduce((accumulator, item) => {
      if (item?.ip) {
        accumulator[item.ip] = !item.in_use;
      }
      return accumulator;
    }, {});
    const summary = summarizeProvisionIpCheckResults(results);

    return {
      ok: summary.tone !== 'danger',
      checkedAt: new Date().toISOString(),
      results: availabilityResults,
      summary,
    };
  }

  async function checkProvisionIpAvailability() {
    if (currentStep?.id !== 'provision-nodes' || busyRef.current || provisionIpChecking) {
      return {
        ok: false,
        error: 'Wait until the current action finishes before checking IPs again.',
      };
    }

    setProvisionIpChecking(true);
    setError('');
    setNotice('Checking IP addresses...');

    try {
      const result = await fetchProvisionIpAvailability();
      if (result.checkedAt) {
        setProvisionIpCheckState({
          checkedAt: result.checkedAt,
          results: result.results || {},
        });
      }

      if (result.ok) {
        setNotice(result.summary?.label || 'IP addresses are free.');
        return result;
      }

      const message = result.error || result.summary?.label || 'One or more IP addresses are already in use.';
      setError(message);
      setNotice(message);
      return result;
    } catch (availabilityError) {
      const message = availabilityError instanceof Error ? availabilityError.message : 'Failed to check IP availability.';
      setError(message);
      setNotice(message);
      return { ok: false, error: message };
    } finally {
      setProvisionIpChecking(false);
    }
  }

  function handleStartNewSetup() {
    const firstStepId = questionSteps[0]?.id || 'provision-nodes';
    setHasStarted(true);
    setWizardPhase('questions');
    setSelectedStepId(firstStepId);
    setAnswers({});
    setClusterId('');
    setClusterCreatedAt('');
    setClusterInstanceId('');
    setCluster(null);
    setLogs([]);
    setActiveJob(null);
    setError('');
    setNotice('Starting a new setup.');
    setProvisionSuggestionsReadyState(false);
    setProvisionSuggestionRevision(0);
    clusterIdRef.current = '';
    clusterCreatedAtRef.current = '';
    clusterInstanceIdRef.current = '';
    selectedStepIdRef.current = firstStepId;
    provisionDirtyFieldsRef.current = new Set();
    provisionSuggestionKeyRef.current = '';
    provisionSuggestionSnapshotRef.current = {};
    placementSuggestionKeyRef.current = '';
    clearInstallStepLogs();
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
      selectedStepIdRef.current = imported.selectedStepId || '';
      setClusterId(imported.clusterId);
      setClusterCreatedAt(imported.clusterCreatedAt);
      setClusterInstanceId(imported.clusterInstanceId);
      setHasStarted(true);
      setWizardPhase('questions');
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
      setProvisionSuggestionRevision(0);
      clearInstallStepLogs();
      setNotice('Imported saved wizard answers.');
    } catch (importError) {
      const message = importError instanceof Error ? importError.message : 'Could not import the answers file.';
      setError(message);
    }
  }

  useEffect(() => {
    if (wizardPhase !== 'install') {
      return;
    }

    const latestJobId = currentInstallStep?.latest_job?.id;
    if (!latestJobId) {
      return;
    }

    let cancelled = false;

    (async () => {
      try {
        const logsData = await requestJson(`/api/jobs/${encodeURIComponent(latestJobId)}/logs`);
        if (!cancelled) {
          const lines = Array.isArray(logsData?.lines) ? logsData.lines : [];
          if (lines.length > 0) {
            setInstallStepLogs(currentInstallStep.id, lines);
          }
        }
      } catch {
        // Keep the cached output for this step until fresh output is available.
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [currentInstallStep?.latest_job?.id, selectedStepId, wizardPhase]);

  const currentDraft = currentStep
    ? buildProvisionQuestionDraft({
      step: currentStep,
      answers,
      suggestionSnapshot: provisionSuggestionSnapshotRef.current,
      dirtyFields: provisionDirtyFieldsRef.current,
    })
    : {};
  const placementBoard = currentStep?.id === 'provision-nodes'
    ? buildProvisionPlacementBoard(currentStep.inputs || [], currentDraft, proxmoxResources)
    : null;
  const placementSuggestionKey = currentStep?.id === 'provision-nodes'
    ? buildPlacementSuggestionKey(placementBoard)
    : '';
  const provisionVmIpRows = currentStep?.id === 'provision-nodes'
    ? buildProvisionVmIpRows(
      placementBoard?.vmPlan || [],
      currentDraft,
      provisionSuggestionSnapshotRef.current,
      provisionIpCheckState.results,
    )
    : [];
  const provisionVmIpValidation = currentStep?.id === 'provision-nodes'
    ? validateProvisionVmIpRows(provisionVmIpRows)
    : { ok: true, error: '', invalidRows: [], duplicateRows: [] };
  const provisionIpCheckSummary = currentStep?.id === 'provision-nodes' && provisionIpCheckState.checkedAt
    ? summarizeProvisionIpCheckResults(
      Object.entries(provisionIpCheckState.results || {}).map(([ip, free]) => ({ ip, in_use: !free })),
    )
    : null;
  const provisionSubnet = provisionSuggestionSnapshotRef.current?.subnet
    || (currentDraft.vip_ip
      ? `${String(currentDraft.vip_ip).split('.').slice(0, 3).join('.')}.0/24`
      : '192.168.1.0/24');
  const provisionInputGroups = currentStep?.id === 'provision-nodes'
    ? getProvisionInputGroups(currentStep.inputs || [])
    : { vmInputs: [], networkInputs: [] };
  const provisionScaleSummary = currentStep?.id === 'provision-nodes'
    ? buildProvisionScaleSummary(
      currentDraft.scale_percent ?? 90,
      currentStep.inputs || [],
      currentDraft,
      proxmoxResources,
    )
    : null;
  useEffect(() => {
    if (currentStep?.id !== 'provision-nodes' || !placementBoard?.hostCards?.length) {
      return;
    }

    if (hasPlacementAssignments(currentDraft.vm_node_map)) {
      return;
    }

    if (!placementSuggestionKey || placementSuggestionKeyRef.current === placementSuggestionKey) {
      return;
    }

    placementSuggestionKeyRef.current = placementSuggestionKey;
    void applyProvisionPlacementHelp();
  }, [
    applyProvisionPlacementHelp,
    currentStep?.id,
    currentDraft.vm_node_map,
    placementBoard,
    placementSuggestionKey,
  ]);
  const provisionStepValid = currentStep?.id === 'provision-nodes'
    ? provisionVmIpValidation.ok
    : true;
  const questionInputsValid = currentStep
    ? (currentStep.inputs || []).every((input) => hasRequiredValue(input, currentDraft[input.id]))
    : false;
  const primaryActionDisabled = !provisionStepValid || !questionInputsValid || busy || provisionIpChecking || provisionIpSuggestionsLoading;
  const primaryActionLabel = isQuestionPhase
    ? ((currentStep?.id === 'provision-nodes' && (provisionIpChecking || provisionIpSuggestionsLoading))
      ? 'Checking...'
      : (questionStepIndex === questionSteps.length - 1 ? 'Continue to installation' : 'Next'))
    : '';
  const primaryActionHelperText = isQuestionPhase
    ? (currentStep?.id === 'provision-nodes' && (provisionIpChecking || provisionIpSuggestionsLoading)
      ? 'Checking IP addresses.'
      : currentStep?.id === 'provision-nodes' && !provisionVmIpValidation.ok
      ? 'Fill in the Talos IP addresses before continuing.'
      : !questionInputsValid
      ? 'Fill in the required values before continuing.'
      : questionStepIndex === questionSteps.length - 1
        ? 'The questions are complete. Continue to the installation steps.'
        : 'Review the values on this page and continue to the next question.')
    : '';
  const installStepCount = setupSteps.length;
  const installStepBlocked = currentStep?.status === 'locked';
  const installInProgress = Boolean(visibleActiveJob?.id && ['pending', 'running', 'cancel_requested'].includes(visibleActiveJob.status))
    || currentStep?.status === 'running';
  const installButtonDisabled = !currentStep
    || busy
    || installInProgress
    || installStepBlocked
    || (currentStep?.id === 'provision-nodes' && !provisionStepValid);
  const remainingInstallableSteps = setupSteps
    .slice(safeInstallStepIndex)
    .filter((step) => step.status !== 'done' && step.status !== 'configured');
  const installAllDisabled = !currentStep
    || busy
    || installInProgress
    || installStepBlocked
    || remainingInstallableSteps.length === 0
    || (currentStep?.id === 'provision-nodes' && !provisionStepValid);

  const wizardGuide = getWizardGuide(currentStep?.id);
  const activeStepIsChoice = currentStep?.id === 'choose-ingress-route';
  const activeStepIsQuestion = Boolean(currentStep?.inputs?.length) || activeStepIsChoice || currentStep?.id === 'provision-nodes';
  const activeStepTitle = getDisplayStepTitle(currentStep);
  const activeStepPresentation = getStepPresentation(currentStep);
  const questionStepCount = questionSteps.length;
  const showImportButton = !isInstallPhase && !model.completion && currentStep?.id !== 'provision-nodes';

  if (!hasStarted) {
    return (
      <div className="wizard-shell wizard-shell-start">
        {renderTopBar({ onImportClick: handleImportClick, showImportButton: false })}
        {isBootstrapping || error || notice ? (
          <div className={`wizard-banner ${error ? 'is-error' : 'is-notice'}`}>
            <div>
              <strong>{error ? 'Something needs attention.' : isBootstrapping ? 'Loading cluster data…' : 'Status'}</strong>
              <p>
                {error
                  ? error
                  : isBootstrapping
                    ? 'Twinbox is checking the current cluster state. This can take a moment.'
                    : notice}
              </p>
            </div>
          </div>
        ) : null}
        <div className="wizard-start-screen">
          <section className="wizard-start-card">
            <div className="wizard-start-hero">
              <img src={heroIllustrationUrl} alt="" aria-hidden="true" />
            </div>
            <p className="eyebrow">Twinbox setup wizard</p>
            <h1>Install a Twinbox cluster</h1>
            <p className="wizard-start-copy">
              This wizard collects the setup values Twinbox needs, and then installs the cluster in one long automatic run.
            </p>

            <div className="wizard-start-actions">
              <button className="button button-primary" type="button" onClick={handleStartNewSetup}>
                Start a new setup
              </button>
            </div>
          </section>
        </div>

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

  return (
    <div className="wizard-shell">
      {renderTopBar({ onImportClick: handleImportClick, showImportButton })}
      {isBootstrapping || error || notice ? (
        <div className={`wizard-banner ${error ? 'is-error' : 'is-notice'}`}>
          <div>
            <strong>{error ? 'Something needs attention.' : isBootstrapping ? 'Loading cluster data…' : 'Status'}</strong>
            <p>
              {error
                ? error
                : isBootstrapping
                  ? 'Twinbox is checking the current cluster state. This can take a moment.'
                  : notice}
            </p>
          </div>
        </div>
      ) : null}

      <main className="wizard-layout wizard-layout-minimal">
        <section className={`wizard-workspace wizard-workspace-minimal ${isInstallPhase ? 'wizard-workspace-install' : ''}`}>
          {!isInstallPhase ? (
            <div className="wizard-workspace-header wizard-workspace-header-minimal">
              <div className="wizard-workspace-copy">
                <p className="eyebrow">
                  {isQuestionPhase && currentStep
                    ? `Question ${questionStepIndex + 1} of ${questionStepCount}`
                    : currentStep
                      ? `Install step ${safeInstallStepIndex + 1} of ${installStepCount}`
                      : 'Twinbox installer'}
                </p>
                <div className="wizard-workspace-stepline">
                  {renderStepIcon(activeStepPresentation, 'wizard-step-icon wizard-step-icon-large')}
                  <div className="wizard-workspace-stepline-copy">
                    <h1>{model.completion ? model.completion.title : activeStepTitle || 'Question'}</h1>
                    <p className="wizard-intro wizard-step-pitch">
                      {model.completion
                        ? model.completion.summary
                        : isQuestionPhase
                          ? currentStep?.summary || model.activity.summary
                          : model.activity.summary}
                    </p>
                    {isQuestionPhase && activeStepIsQuestion ? (
                      <div className="wizard-guide-panel">
                        <div className="wizard-guide-copy">
                          <p className="eyebrow">{wizardGuide.eyebrow}</p>
                          <h2>{wizardGuide.title}</h2>
                          <p>{wizardGuide.intro}</p>
                          <ul className="wizard-guide-list">
                            {wizardGuide.checklist.map((item) => (
                              <li key={item}>{item}</li>
                            ))}
                          </ul>
                          {wizardGuide.helpLink ? (
                            <a className="wizard-guide-link" href={wizardGuide.helpLink.href} target="_blank" rel="noreferrer">
                              {wizardGuide.helpLink.label}
                            </a>
                          ) : null}
                        </div>
                        <div className="wizard-screenshot-card">
                          <span className="wizard-screenshot-label">{wizardGuide.screenshotTitle}</span>
                          {wizardGuide.screenshotLines.map((line) => (
                            <strong key={line}>{line}</strong>
                          ))}
                        </div>
                      </div>
                    ) : null}
                  </div>
                </div>
              </div>
            </div>
          ) : null}

          {model.completion ? (
            <section className="wizard-completion-panel">
              <article className="wizard-card wizard-card-accent wizard-completion-card">
                <p className="eyebrow">Installation complete</p>
                <h2>{model.completion.title}</h2>
                <p>{model.completion.summary}</p>
                <div className="wizard-completion-actions">
                  <button className="button button-primary" type="button" onClick={handleExportAnswers}>
                    Export all answers
                  </button>
                  {adminDashboardUrl ? (
                    <a
                      className="button button-secondary"
                      href={adminDashboardUrl}
                      target="_blank"
                      rel="noopener noreferrer"
                    >
                      Open Admin Dashboard
                    </a>
                  ) : (
                    <button className="button button-secondary" type="button" disabled>
                      Open Admin Dashboard
                    </button>
                  )}
                </div>
              </article>
            </section>
          ) : isInstallPhase ? (
            <section className="wizard-install-stage" aria-label="Installation output and controls">
              <div className="wizard-install-stage-head">
                {renderStepIcon(activeStepPresentation, 'wizard-step-icon wizard-step-icon-large wizard-install-stage-icon')}
                <p className="eyebrow">
                  {currentStep?.status === 'running'
                    ? `Now installing step ${safeInstallStepIndex + 1} of ${installStepCount}`
                    : `Install step ${safeInstallStepIndex + 1} of ${installStepCount}`}
                </p>
                <h2>{currentStep?.title || 'Installation output'}</h2>
                <p className="wizard-step-summary">
                  {currentStep?.summary || 'Watch the output below while Twinbox runs the scripts for this step.'}
                </p>
              </div>
              <section
                ref={liveOutputRef}
                className={`wizard-card wizard-output-panel wizard-output-panel-minimal wizard-install-output ${model.activity.runtime.isLive ? 'is-live' : ''}`}
                aria-label={`Installation output for ${currentStep?.title || 'the current install step'}`}
              >
                <div className="wizard-output-header wizard-output-header-install">
                  <div className="wizard-output-step-label">
                    <p className="eyebrow">Output</p>
                    <strong>{currentStep?.title || 'Current install step'}</strong>
                  </div>
                  <span className={`wizard-status ${model.activity.runtime.isLive ? 'is-live' : ''}`}>
                    {model.activity.runtime.runState}
                  </span>
                </div>

                <div className="wizard-log-viewport wizard-log-viewport-install" ref={liveLogViewportRef}>
                  <pre className="wizard-log-output">{model.activity.rawLogOutput || ''}</pre>
                </div>
              </section>

              <div className="wizard-install-actions">
                <div className="wizard-card-actions wizard-install-actions-row">
                  <button
                    className="button button-secondary"
                    type="button"
                      onClick={() => {
                        if (previousInstallStep?.id) {
                          selectInstallStep(previousInstallStep.id);
                        }
                      }}
                    disabled={!previousInstallStep || installInProgress}
                  >
                    Previous
                  </button>
                  <button
                    className="button button-secondary"
                    type="button"
                      onClick={() => {
                        if (nextInstallStep?.id) {
                          selectInstallStep(nextInstallStep.id);
                          setNotice(`Moved to ${nextInstallStep.title}.`);
                        }
                      }}
                    disabled={!nextInstallStep || installInProgress}
                  >
                    Next
                  </button>
                  <button
                    className="button button-primary"
                    type="button"
                    onClick={() => handleInstallCurrentStep(currentStep)}
                    disabled={installButtonDisabled}
                  >
                    Install
                  </button>
                  <button
                    className="button button-primary"
                    type="button"
                    onClick={() => handleInstallAllSteps(currentStep?.id)}
                    disabled={installAllDisabled}
                  >
                    Install all
                  </button>
                  {installInProgress ? (
                    <button
                      className="button button-danger"
                      type="button"
                      onClick={handleCancelActiveJob}
                    >
                      Stop
                    </button>
                  ) : null}
                </div>
              </div>
            </section>
          ) : (
            <div className="wizard-flow wizard-flow-minimal">
              <section className="wizard-card wizard-step-workspace wizard-step-workspace-minimal">
                {currentStep?.id === 'provision-nodes' ? (
                  <>
                    <section className="wizard-step-actions-panel" aria-label="Step 1 helpers">
                      <div className="wizard-step-actions-panel-head">
                        <div>
                          <p className="eyebrow">Quick actions</p>
                          <h3>Optional help for Talos sizing, placement, and IPs</h3>
                        </div>
                        <p className="wizard-input-block-note">
                          You can skip these and fill every field by hand. Next stays available when the required values are valid.
                        </p>
                      </div>
                      <div className="wizard-step-actions-panel-actions">
                        <button className="button button-secondary" type="button" onClick={handleImportClick} disabled={busy || provisionIpChecking}>
                          Load saved answers
                        </button>
                      </div>
                    </section>

                    <section className="wizard-input-block is-cluster" aria-label="Cluster identity">
                      <div className="wizard-input-block-head">
                        <div>
                          <p className="eyebrow">0. Cluster identity</p>
                          <h3>Use the cluster name from the wizard selection</h3>
                        </div>
                      </div>

                      <dl className="wizard-network-summary">
                        <div>
                          <dt>Cluster name</dt>
                          <dd>{catalog.cluster_slug || 'prd'}</dd>
                        </div>
                      </dl>

                      <p className="wizard-input-block-note">
                        Twinbox saves this name automatically from the wizard choice, so you do not need to enter it again here.
                      </p>
                    </section>

                    <section className="wizard-input-block" aria-label="VM sizing">
                      <div className="wizard-input-block-head">
                        <div>
                          <p className="eyebrow">1. VM sizing</p>
                          <h3>Scale the cluster footprint</h3>
                        </div>
                        <p className="wizard-input-block-note">
                          The sliders set the starting footprint and worker disk share; the manual fields below stay editable.
                        </p>
                      </div>
                      <div className="wizard-input-grid">
                        {provisionInputGroups.vmInputs.map((input) => (
                          <InputField
                            key={input.id}
                            stepId={currentStep.id}
                            input={input}
                            value={currentDraft[input.id]}
                            onChange={(inputId, value) => updateAnswer(currentStep.id, inputId, value)}
                          />
                        ))}
                      </div>
                      <p className="wizard-input-block-note">
                        Control plane nodes are fixed at 4 GB RAM and 10 GB disk. Worker disks default to 80% of the free space shared across the three Proxmox hosts and can be tuned with the slider.
                      </p>
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
                      onReset={applyProvisionPlacementHelp}
                    />

                    <section className="wizard-input-block is-network" aria-label="Network and addressing">
                      <div className="wizard-input-grid">
                        {provisionInputGroups.networkInputs.map((input) => (
                          <InputField
                            key={input.id}
                            stepId={currentStep.id}
                            input={input}
                            value={currentDraft[input.id]}
                            onChange={(inputId, value) => updateAnswer(currentStep.id, inputId, value)}
                          />
                        ))}
                      </div>

                      <div className="wizard-card-actions wizard-card-actions-inline wizard-network-help-row">
                        <button className="button button-secondary" type="button" onClick={applyProvisionIpHelp} disabled={busy || provisionIpChecking || provisionIpSuggestionsLoading}>
                          {provisionIpSuggestionsLoading ? 'Assigning free IPs…' : 'Help me with free IPs'}
                        </button>
                      </div>

                      {provisionIpSuggestionsLoading ? (
                        <p className="wizard-network-check-summary is-pending" aria-live="polite">
                          Checking the local subnet for free IP addresses. Please wait while Twinbox fills them in automatically.
                        </p>
                      ) : null}

                      {provisionIpCheckSummary ? (
                        <p className={`wizard-network-check-summary is-${provisionIpCheckSummary.tone}`}>
                          {provisionIpCheckSummary.label}
                        </p>
                      ) : null}

                      <div className="wizard-network-vm-list">
                        <div className="wizard-network-vm-list-head">
                          <div>
                            <p className="eyebrow">Per-VM IPs</p>
                            <h4>Assign addresses to each VM</h4>
                          </div>
                        </div>

                        <div className="wizard-network-vm-items">
                          {provisionVmIpRows.map((vm) => {
                            const currentVmIpMap = currentDraft.vm_ip_map && typeof currentDraft.vm_ip_map === 'object' && !Array.isArray(currentDraft.vm_ip_map)
                              ? currentDraft.vm_ip_map
                              : {};
                            const onVmIpChange = (value) => {
                              updateAnswer(currentStep.id, 'vm_ip_map', {
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

                                <label className="wizard-field wizard-field-inline" htmlFor={`${currentStep.id}-${vm.name}-ip`}>
                                  <span className="wizard-field-label">IP address</span>
                                  <input
                                    id={`${currentStep.id}-${vm.name}-ip`}
                                    type="text"
                                    value={vm.value}
                                    onChange={(event) => onVmIpChange(event.target.value)}
                                    inputMode="decimal"
                                    placeholder="Enter IP address"
                                  />
                                  <small>
                                    {vm.isSuggested
                                      ? 'This IP was filled by the free-IP helper.'
                                      : 'This value is validated when you continue to the next step.'}
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
                      {(currentStep?.inputs || []).map((input) => (
                        <InputField
                        key={input.id}
                        stepId={currentStep.id}
                        input={input}
                        value={currentDraft[input.id]}
                        onChange={(inputId, value) => updateAnswer(currentStep.id, inputId, value)}
                      />
                    ))}
                    {(!currentStep?.inputs || currentStep.inputs.length === 0) && (
                      <p className="wizard-empty">
                        {isQuestionPhase
                          ? 'This step does not need extra inputs. Review the page and continue.'
                          : 'This install step does not need extra inputs. Use Install to run it and watch the output below.'}
                      </p>
                    )}
                  </div>
                )}

                <div className="wizard-card-actions">
                  {isQuestionPhase && previousQuestionStep ? (
                    <button
                      className="button button-secondary"
                      type="button"
                      onClick={() => setSelectedStepId(previousQuestionStep.id)}
                    >
                      Previous
                    </button>
                  ) : null}
                  {isQuestionPhase ? (
                    <button
                      className="button button-primary"
                      type="button"
                      onClick={handlePrimaryAction}
                      disabled={primaryActionDisabled}
                    >
                      {primaryActionLabel}
                    </button>
                  ) : null}
                </div>

                {isQuestionPhase ? (
                  <p className="wizard-helper">{primaryActionHelperText}</p>
                ) : null}
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
