import { useEffect, useMemo, useRef, useState } from 'react';

import './App.css';
import heroIllustrationUrl from './assets/hero-illustration.svg';
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
  getWizardSteps,
  restoreUiState,
  serializeUiState,
  STORAGE_KEY,
  formatState,
} from './journey.js';
import { getQuestionSteps } from './question-flow.js';
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

function hasRequiredValue(input, value) {
  if (!input?.required) {
    return true;
  }

  if (input.type === 'boolean') {
    return typeof value === 'boolean';
  }

  if (input.type === 'integer') {
    return Number.isFinite(Number(value));
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

function formatInputValue(input, value) {
  if (input.type === 'boolean') {
    return Boolean(value);
  }

  if (typeof value === 'number' && Number.isNaN(value)) {
    return '';
  }

  return value ?? '';
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
  'name',
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
        {board.managementVm ? (
          <article className="wizard-placement-host wizard-placement-management-card" aria-label="Management VM">
            <header className="wizard-placement-host-head">
              <div>
                <strong>Management VM</strong>
                <span>{board.managementVm.name || 'Twinbox management VM'} · VMID {board.managementVm.vmid ?? '—'}</span>
              </div>
              <span className="wizard-status-badge is-neutral">Fixed</span>
            </header>

            <div className="wizard-placement-host-body">
              <div className="wizard-placement-fixed-details">
                <span>Currently on {board.managementVm.node || 'an unknown Proxmox host'}</span>
                <p>It stays fixed and does not move with the cluster VMs.</p>
              </div>
            </div>
          </article>
        ) : null}

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
  const [provisionIpCheckState, setProvisionIpCheckState] = useState({
    checkedAt: '',
    results: {},
  });
  const [provisionIpChecking, setProvisionIpChecking] = useState(false);
  const [hasStarted, setHasStarted] = useState(false);
  const [wizardPhase, setWizardPhase] = useState('questions');
  const placementSuggestionKeyRef = useRef('');
  const wizardPhaseRef = useRef('questions');

  useEffect(() => {
    setSelectedStepId('');
    setClusterId('');
    setClusterCreatedAt('');
    setClusterInstanceId('');
    setAnswers({});
    setHasStarted(false);
    setWizardPhase('questions');
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

  useEffect(() => {
    if (!hasStarted || wizardPhase !== 'questions') {
      return;
    }

    const firstQuestionId = questionSteps[0]?.id || '';
    if (!firstQuestionId) {
      return;
    }

    if (!selectedStepId || !questionSteps.some((step) => step.id === selectedStepId)) {
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

    if (!selectedStepId || !setupSteps.some((step) => step.id === selectedStepId)) {
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
      liveLogAutoScrollRef.current = distanceFromBottom < 72;
    };

    viewport.addEventListener('scroll', handleScroll, { passive: true });
    handleScroll();

    return () => {
      viewport.removeEventListener('scroll', handleScroll);
    };
  }, []);

  useEffect(() => {
    if (!liveLogAutoScrollRef.current) {
      return;
    }

    const viewport = liveLogViewportRef.current;
    if (viewport) {
      viewport.scrollTop = viewport.scrollHeight;
    }
  }, [logs, activeJob?.id, model?.activity?.runtime?.currentStage]);

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
      body.vm_size_map = placement.vmSizeMap;
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
    if (!isQuestionPhase || !currentStep || busyRef.current) {
      return;
    }

    if (currentStep?.id === 'provision-nodes' && !provisionStepValid) {
      const message = provisionVmIpValidation.error || 'Step 1 is still preparing. Wait until the button says Next.';
      setNotice(message);
      return;
    }

    if (currentStep?.id === 'provision-nodes') {
      const availabilityCheck = await checkProvisionIpAvailability();
      if (!availabilityCheck.ok) {
        return;
      }
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

  async function handleReinstallStep(step) {
    if (!step || busyRef.current || step.status === 'running' || step.status === 'locked') {
      return;
    }

    if (step.id === 'provision-nodes' && !provisionStepValid) {
      const message = provisionVmIpValidation.error || 'Step 1 is still preparing. Wait until the placement and IP suggestions are ready.';
      setNotice(message);
      return;
    }

    if (step.status === 'skipped') {
      await handleUnskipAndExecute(step);
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
      const message = provisionVmIpValidation.error || 'Step 1 is still preparing. Wait until the placement and IP suggestions are ready.';
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

    const currentSteps = getWizardSteps(catalog, answersRef.current);
    const startIndex = Math.max(0, currentSteps.findIndex((step) => step.id === fromStepId));
    const pendingSteps = currentSteps
      .slice(startIndex)
      .filter((step) => step.status !== 'done' && step.status !== 'configured');
    if (!pendingSteps.length) {
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

      for (const step of pendingSteps) {
        const currentCatalog = getWizardSteps(currentCatalogData, answersRef.current);
        const currentStep = currentCatalog.find((candidate) => candidate.id === step.id) || step;

        setSelectedStepId(currentStep.id);

        if (currentStep.status === 'done') {
          continue;
        }

        if (currentStep.status === 'configured') {
          continue;
        }

        if (currentStep.status === 'locked') {
          throw new Error(`${currentStep.title} is locked until its dependencies are complete.`);
        }

        const result = currentStep.status === 'skipped'
          ? await handleUnskipAndExecute(currentStep, { manageBusy: false })
          : await executeStep(currentStep, nextClusterId, { manageBusy: false });
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

  function resetPlacementToSuggested() {
    if (!placementBoard || currentStep?.id !== 'provision-nodes') {
      return;
    }

    updateAnswer(currentStep.id, 'vm_node_map', placementBoard.suggestedVmNodeMap || {});
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
    clusterIdRef.current = '';
    clusterCreatedAtRef.current = '';
    clusterInstanceIdRef.current = '';
    selectedStepIdRef.current = firstStepId;
    provisionDirtyFieldsRef.current = new Set();
    provisionSuggestionKeyRef.current = '';
    provisionSuggestionSnapshotRef.current = {};
    placementSuggestionKeyRef.current = '';
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
      setNotice('Imported saved wizard answers.');
    } catch (importError) {
      const message = importError instanceof Error ? importError.message : 'Could not import the answers file.';
      setError(message);
    }
  }

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

  useEffect(() => {
    if (wizardPhase !== 'install') {
      return;
    }

    const latestJobId = currentInstallStep?.latest_job?.id;
    if (!latestJobId) {
      setLogs([]);
      return;
    }

    let cancelled = false;

    (async () => {
      try {
        const logsData = await requestJson(`/api/jobs/${encodeURIComponent(latestJobId)}/logs`);
        if (!cancelled) {
          setLogs(Array.isArray(logsData?.lines) ? logsData.lines : []);
        }
      } catch {
        if (!cancelled) {
          setLogs([]);
        }
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [currentInstallStep?.latest_job?.id, selectedStepId, wizardPhase]);

  const currentDraft = currentStep
    ? buildInitialAnswers([currentStep], answers)[currentStep.id]
    : {};
  useEffect(() => {
    if (currentStep?.id !== 'provision-nodes') {
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

    const suggestionKey = `${managementIp}:${getProvisionNodeCount(currentStep.inputs || [], currentDraft)}`;

    setProvisionSuggestionsReadyState(
      provisionSuggestionKeyRef.current === suggestionKey
      && Object.keys(provisionSuggestionSnapshotRef.current || {}).length > 0,
    );
  }, [clusterInstanceId, currentDraft.controlplane_count, currentDraft.worker_count, currentStep?.id]);

  const placementBoard = currentStep?.id === 'provision-nodes'
    ? buildProvisionPlacementBoard(currentStep.inputs || [], currentDraft, proxmoxResources)
    : null;
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
      currentDraft.scale_percent ?? 30,
      currentStep.inputs || [],
      currentDraft,
      proxmoxResources,
    )
    : null;
  const provisionSuggestionKey = currentStep?.id === 'provision-nodes'
    ? `${window.location.hostname}:${getProvisionNodeCount(currentStep.inputs || [], currentDraft)}`
    : '';
  const provisionPlacementReady = currentStep?.id !== 'provision-nodes' || Boolean(placementBoard?.hostCards?.length);
  const provisionSuggestionsReady = isProvisionSuggestionReady({
    activeStepId: currentStep?.id || '',
    suggestionKey: provisionSuggestionKey,
    currentSuggestionKey: provisionSuggestionKeyRef.current,
    suggestionSnapshot: provisionSuggestionSnapshotRef.current,
  });
  const provisionStepReady = provisionPlacementReady && provisionSuggestionsReady;
  const provisionStepValid = provisionStepReady && provisionVmIpValidation.ok;
  const stepOnePending = currentStep?.id === 'provision-nodes' && !provisionStepReady;
  const questionInputsValid = currentStep
    ? (currentStep.inputs || []).every((input) => hasRequiredValue(input, currentDraft[input.id]))
    : false;
  const primaryActionDisabled = stepOnePending || !provisionStepValid || !questionInputsValid || busy || provisionIpChecking;
  const primaryActionLabel = isQuestionPhase
    ? ((currentStep?.id === 'provision-nodes' && provisionIpChecking)
      ? 'Checking...'
      : (questionStepIndex === questionSteps.length - 1 ? 'Continue to installation' : 'Next'))
    : '';
  const primaryActionHelperText = isQuestionPhase
    ? (currentStep?.id === 'provision-nodes' && provisionIpChecking
      ? 'Checking IP addresses again before moving forward.'
      : !questionInputsValid
      ? 'Fill in the required values before continuing.'
      : stepOnePending
        ? (!provisionPlacementReady ? 'Waiting for Proxmox host data before continuing.' : 'Preparing IP suggestions before continuing.')
        : questionStepIndex === questionSteps.length - 1
          ? 'The questions are complete. Continue to the installation steps.'
          : 'Review the values on this page and continue to the next question.')
    : '';
  const installStepCount = setupSteps.length;
  const isCurrentStepComplete = currentStep?.status === 'done' || currentStep?.status === 'configured';
  const stepHasRunBefore = Boolean(currentStep?.latest_job) || ['done', 'configured', 'failed', 'canceled', 'skipped'].includes(currentStep?.status || '');
  const installStepBlocked = currentStep?.status === 'locked';
  const installButtonDisabled = !currentStep
    || busy
    || currentStep?.status === 'running'
    || installStepBlocked
    || isCurrentStepComplete
    || (currentStep?.id === 'provision-nodes' && !provisionStepValid);
  const reinstallButtonDisabled = !currentStep
    || busy
    || currentStep?.status === 'running'
    || installStepBlocked
    || !stepHasRunBefore
    || (currentStep?.id === 'provision-nodes' && !provisionStepValid);
  const remainingInstallableSteps = setupSteps
    .slice(safeInstallStepIndex)
    .filter((step) => step.status !== 'done' && step.status !== 'configured');
  const installAllDisabled = !currentStep
    || busy
    || installStepBlocked
    || remainingInstallableSteps.length === 0
    || (currentStep?.id === 'provision-nodes' && !provisionStepValid);

  useEffect(() => {
    if (currentStep?.id !== 'provision-nodes') {
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
          const activeProvisionDraft = current[currentStep.id] || {};
          const merged = mergeSuggestedProvisionDraft({
            currentDraft: activeProvisionDraft,
            previousSuggested: buildSuggestedProvisionInputs(provisionSuggestionSnapshotRef.current),
            suggestionData,
            stepInputs: currentStep.inputs || [],
            dirtyFields: Object.fromEntries([...provisionDirtyFieldsRef.current].map((fieldId) => [fieldId, true])),
          });

          return {
            ...current,
            [currentStep.id]: merged,
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
  }, [clusterInstanceId, currentDraft.controlplane_count, currentDraft.worker_count, currentStep?.id]);

  useEffect(() => {
    if (!placementBoard || currentStep?.id !== 'provision-nodes') {
      return;
    }

    const suggestionKey = `${clusterInstanceIdRef.current || clusterIdRef.current || ''}:${currentStep.id}`;
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
    updateAnswer(currentStep.id, 'vm_node_map', placementBoard.suggestedVmNodeMap || {});
  }, [clusterInstanceId, clusterId, currentDraft, currentStep, placementBoard]);

  const wizardGuide = getWizardGuide(currentStep?.id);
  const activeStepIsChoice = currentStep?.id === 'choose-ingress-route';
  const activeStepIsQuestion = Boolean(currentStep?.inputs?.length) || activeStepIsChoice || currentStep?.id === 'provision-nodes';
  const activeStepTitle = getDisplayStepTitle(currentStep);
  const activeStepPresentation = getStepPresentation(currentStep);
  const questionStepCount = questionSteps.length;
  const isInstallPhase = hasStarted && wizardPhase === 'install' && !model.completion;

  if (!hasStarted) {
    return (
      <div className="wizard-shell wizard-shell-start">
        {renderTopBar({ onImportClick: handleImportClick, showImportButton: false })}
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
      {renderTopBar({ onImportClick: handleImportClick, showImportButton: true })}

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
            <section className="wizard-finish-grid">
              <article className="wizard-card wizard-card-accent">
                <p className="eyebrow">Installation complete</p>
                <h2>{model.completion.stepTitle}</h2>
                <p>{model.completion.summary}</p>
                <div className="wizard-card-actions">
                  <button className="button button-primary" type="button" onClick={handleExportAnswers}>
                    Export all answers
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
          ) : isInstallPhase ? (
            <section className="wizard-install-stage" aria-label="Installation output and controls">
              <section
                ref={liveOutputRef}
                className={`wizard-card wizard-output-panel wizard-output-panel-minimal wizard-install-output ${model.activity.runtime.isLive ? 'is-live' : ''}`}
                aria-label={`Installation output for ${currentStep?.title || 'the current install step'}`}
              >
                <div className="wizard-output-header wizard-output-header-install">
                  <p className="eyebrow">Output</p>
                  <span className={`wizard-status ${model.activity.runtime.isLive ? 'is-live' : ''}`}>
                    {model.activity.runtime.runState}
                  </span>
                </div>

                <div className="wizard-log-viewport wizard-log-viewport-install" ref={liveLogViewportRef}>
                  <pre className="wizard-log-output">{model.activity.rawLogOutput}</pre>
                </div>
              </section>

              <div className="wizard-install-actions">
                <div className="wizard-card-actions wizard-install-actions-row">
                  <button
                    className="button button-secondary"
                    type="button"
                    onClick={() => {
                      if (previousInstallStep?.id) {
                        setSelectedStepId(previousInstallStep.id);
                      }
                    }}
                    disabled={!previousInstallStep}
                  >
                    Previous
                  </button>
                  <button
                    className="button button-secondary"
                    type="button"
                    onClick={() => {
                      if (nextInstallStep?.id) {
                        setSelectedStepId(nextInstallStep.id);
                        setNotice(`Moved to ${nextInstallStep.title}.`);
                      }
                    }}
                    disabled={!nextInstallStep}
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
                    className="button button-secondary"
                    type="button"
                    onClick={() => handleReinstallStep(currentStep)}
                    disabled={reinstallButtonDisabled}
                  >
                    Reinstall
                  </button>
                  <button
                    className="button button-primary"
                    type="button"
                    onClick={() => handleInstallAllSteps(currentStep?.id)}
                    disabled={installAllDisabled}
                  >
                    Install all
                  </button>
                </div>
              </div>
            </section>
          ) : (
            <div className="wizard-flow wizard-flow-minimal">
              <section className="wizard-card wizard-step-workspace wizard-step-workspace-minimal">
                {currentStep?.id === 'provision-nodes' ? (
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
                            stepId={currentStep.id}
                            input={input}
                            value={currentDraft[input.id]}
                            onChange={(inputId, value) => updateAnswer(currentStep.id, inputId, value)}
                          />
                        ))}
                      </div>
                      <p className="wizard-input-block-note">
                        Control plane nodes are fixed at 4 GB RAM and 10 GB disk. Worker disks scale from the selected host&apos;s free space and the slider percentage.
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
                      onReset={resetPlacementToSuggested}
                    />

                    <section className="wizard-input-block is-network" aria-label="Network and addressing">
                      <div className="wizard-input-block-head">
                        <div>
                          <p className="eyebrow">3. Network and addressing</p>
                          <h3>Keep VM scale separate from networking</h3>
                        </div>
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
                            stepId={currentStep.id}
                            input={input}
                            value={currentDraft[input.id]}
                            onChange={(inputId, value) => updateAnswer(currentStep.id, inputId, value)}
                          />
                        ))}
                      </div>

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

                        <div className="wizard-card-actions wizard-card-actions-inline wizard-network-check-row">
                          <button
                            className="button button-secondary"
                            type="button"
                            onClick={() => checkProvisionIpAvailability()}
                            disabled={busy || provisionIpChecking || !provisionStepReady}
                          >
                            {provisionIpChecking ? 'Checking...' : 'Check for free IP addresses'}
                          </button>
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
