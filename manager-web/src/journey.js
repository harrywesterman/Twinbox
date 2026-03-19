export const STORAGE_KEY = 'twinbox.mission-control.v1';

export const defaultForm = {
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

export const phaseDefinitions = [
  {
    id: 'foundation',
    title: 'Foundation',
    summary: 'Confirm the management plane, capture the cluster shape, and reserve the Talos IP range.',
    steps: [
      {
        id: 'foundation-overview',
        title: 'Review the management environment',
        shortTitle: 'Environment review',
        kind: 'review',
        etaMinutes: 3,
        summary: 'Twinbox checks whether the management plane is alive and whether the current release can continue on this Management VM.',
        why: 'This avoids starting a long installation path before the management API, runtime, and baseline network assumptions are visible to the operator.',
        risk: 'Trusted LAN assumptions still apply in this build.',
      },
      {
        id: 'foundation-cluster-profile',
        title: 'Shape the Talos cluster',
        shortTitle: 'Cluster profile',
        kind: 'input',
        fields: ['name', 'controlplane_count', 'worker_count', 'cpu_cores', 'memory_mb', 'disk_gb', 'bridge', 'start_vmid'],
        etaMinutes: 5,
        summary: 'Define the cluster topology and the Proxmox resource footprint before Twinbox requests infrastructure.',
        why: 'The management plane needs a stable desired shape for VM count, sizing, and Proxmox addressing before provisioning becomes safe and repeatable.',
        risk: 'These values map directly to Proxmox VM resources.',
      },
      {
        id: 'foundation-network-plan',
        title: 'Reserve the Talos address plan',
        shortTitle: 'Network plan',
        kind: 'input',
        fields: ['vip_ip', 'start_ip'],
        etaMinutes: 4,
        summary: 'Capture the VIP and the first node address so Twinbox can plan the Talos cluster without shell access later.',
        why: 'Address collisions are one of the easiest ways to derail bootstrap. The operator should validate the reserved range before provisioning starts.',
        risk: 'VIP and node IPs must be free on the management subnet.',
      },
    ],
  },
  {
    id: 'talos-cluster',
    title: 'Talos Cluster',
    summary: 'Provision Talos nodes, bootstrap the cluster, and verify the resulting control plane artifacts.',
    steps: [
      {
        id: 'talos-provision',
        title: 'Provision Talos nodes on Proxmox',
        shortTitle: 'Provision nodes',
        kind: 'action',
        action: 'provision',
        etaMinutes: 8,
        summary: 'Twinbox submits the Talos VM request, tracks the worker job, and records the generated VM IDs and addresses.',
        why: 'The infrastructure baseline has to exist and be recorded before any Talos bootstrap commands can run.',
        risk: 'A failed Proxmox job can leave partially created VMs behind; keep the runtime details visible before retrying.',
      },
      {
        id: 'talos-bootstrap',
        title: 'Bootstrap the Talos cluster',
        shortTitle: 'Bootstrap Talos',
        kind: 'action',
        action: 'bootstrap',
        etaMinutes: 9,
        summary: 'Twinbox applies Talos configs, executes the bootstrap workflow, and captures the kubeconfig artifact on the Management VM.',
        why: 'This is the handoff from raw infrastructure into a usable Kubernetes control plane.',
        risk: 'Bootstrap should only run after the control-plane addresses and VIP have been confirmed.',
      },
      {
        id: 'talos-validate',
        title: 'Validate control-plane access',
        shortTitle: 'Validate access',
        kind: 'review',
        etaMinutes: 3,
        summary: 'Review the generated Talos config directory, control-plane IPs, and worker inventory before Twinbox unlocks later platform phases.',
        why: 'The operator should see exactly what was created before subsequent networking, identity, and GitOps layers depend on it.',
        risk: 'If these artifacts look wrong, stop here and retry before introducing additional platform state.',
      },
    ],
  },
  {
    id: 'core-networking',
    title: 'Core Networking',
    summary: 'Load balancers, ingress, DNS, and certificate plumbing.',
    steps: [
      {
        id: 'networking-load-balancer',
        title: 'Prepare load balancer and ingress policies',
        shortTitle: 'Load balancer',
        kind: 'blocked',
        etaMinutes: 0,
        summary: 'The mission control route is reserved for load balancers, ingress, DNS, and certificate automation.',
        why: 'Networking becomes the next dependency once Talos is healthy, but this release does not execute that phase yet.',
        risk: 'No automated load balancer or ingress configuration exists in this build.',
      },
    ],
  },
  {
    id: 'identity-access',
    title: 'Identity & Access',
    summary: 'Initial IDP, login path, and operator roles.',
    steps: [
      {
        id: 'identity-idp',
        title: 'Configure identity provider and operator access',
        shortTitle: 'IDP setup',
        kind: 'blocked',
        etaMinutes: 0,
        summary: 'This phase will later capture the IDP, login bootstrap, and initial Twinbox roles.',
        why: 'Identity depends on a healthy platform baseline and on networking that can safely expose operator endpoints.',
        risk: 'App-level auth is not available in the current build.',
      },
    ],
  },
  {
    id: 'storage-backups',
    title: 'Storage & Backups',
    summary: 'Storage classes, backup targets, and restore posture.',
    steps: [
      {
        id: 'storage-backups',
        title: 'Plan storage class and backup policy',
        shortTitle: 'Backups',
        kind: 'blocked',
        etaMinutes: 0,
        summary: 'Twinbox will later wire storage classes, retention, and restore validation into the same guided journey.',
        why: 'Backups should be introduced before application installs, not after the platform is already carrying data.',
        risk: 'No automated backup or restore flow exists in the current build.',
      },
    ],
  },
  {
    id: 'gitops-platform',
    title: 'GitOps & Platform Services',
    summary: 'Flux, repositories, and base platform manifests.',
    steps: [
      {
        id: 'gitops-flux',
        title: 'Attach Flux and base platform manifests',
        shortTitle: 'Flux bootstrap',
        kind: 'blocked',
        etaMinutes: 0,
        summary: 'The journey reserves a dedicated stop for GitOps wiring, repository validation, and platform reconciler status.',
        why: 'Once Flux is present, later platform services and curated apps can be delivered declaratively and traced in one place.',
        risk: 'GitOps execution is not implemented in this build.',
      },
    ],
  },
  {
    id: 'applications',
    title: 'Applications',
    summary: 'Curated apps, exposure rules, and platform dependencies.',
    steps: [
      {
        id: 'applications-curated',
        title: 'Install the first curated applications',
        shortTitle: 'Applications',
        kind: 'blocked',
        etaMinutes: 0,
        summary: 'This phase will later orchestrate curated apps with identity hooks, storage dependencies, and exposure defaults.',
        why: 'Applications should arrive only after the cluster, networking, identity, and backups are ready.',
        risk: 'No application installation path is wired yet.',
      },
    ],
  },
  {
    id: 'hardening-operations',
    title: 'Hardening & Operations',
    summary: 'Monitoring, diagnostics, and operational policy.',
    steps: [
      {
        id: 'operations-hardening',
        title: 'Enable diagnostics, observability, and hardening',
        shortTitle: 'Operations',
        kind: 'blocked',
        etaMinutes: 0,
        summary: 'Mission Control reserves this phase for diagnostics, update posture, alerts, and operator guidance.',
        why: 'The installer needs a visible landing zone for day-2 workflows even before every backend contract is implemented.',
        risk: 'Operational guardrails remain manual outside the current Talos workflow.',
      },
    ],
  },
  {
    id: 'go-live',
    title: 'Go Live',
    summary: 'Final acceptance checks and operator handoff.',
    steps: [
      {
        id: 'go-live-checks',
        title: 'Review the final platform handoff',
        shortTitle: 'Go live',
        kind: 'blocked',
        etaMinutes: 0,
        summary: 'The last phase will eventually summarize the delivered environment and the remaining operational checklist before handoff.',
        why: 'A management interface should end with an explicit acceptance checkpoint rather than silently dropping the operator into day-2 mode.',
        risk: 'No full-platform acceptance flow exists in the current release.',
      },
    ],
  },
];

const orderedSteps = phaseDefinitions.flatMap((phase) =>
  phase.steps.map((step) => ({
    ...step,
    phaseId: phase.id,
    phaseTitle: phase.title,
    phaseSummary: phase.summary,
  })),
);

const STEP_INDEX = new Map(orderedSteps.map((step, index) => [step.id, index]));

function normalizeCompletedSteps(value) {
  if (!Array.isArray(value)) return [];
  return [...new Set(value.filter((item) => typeof item === 'string' && STEP_INDEX.has(item)))];
}

function isIntegerInRange(value, min, max) {
  return Number.isInteger(Number(value)) && Number(value) >= min && Number(value) <= max;
}

export function isIPv4(value) {
  if (typeof value !== 'string') return false;
  const parts = value.split('.');
  if (parts.length !== 4) return false;
  return parts.every((part) => /^\d+$/.test(part) && Number(part) >= 0 && Number(part) <= 255);
}

export function formatState(value, fallback) {
  if (!value) return fallback;
  return value
    .toString()
    .replace(/[_-]+/g, ' ')
    .replace(/\b\w/g, (char) => char.toUpperCase());
}

export function toneForStatus(value) {
  if (value === 'done' || value === 'success') return 'success';
  if (value === 'running' || value === 'ready' || value === 'active') return 'active';
  if (value === 'failed' || value === 'danger') return 'danger';
  if (value === 'blocked' || value === 'warning') return 'warning';
  return 'neutral';
}

function validateClusterProfile(form) {
  return [
    {
      label: 'Cluster name',
      detail: 'Non-empty slug for the Twinbox cluster record.',
      ok: typeof form.name === 'string' && form.name.trim() !== '',
    },
    {
      label: 'Control planes',
      detail: 'API accepts 1-15 control-plane nodes.',
      ok: isIntegerInRange(form.controlplane_count, 1, 15),
    },
    {
      label: 'Workers',
      detail: 'API accepts 0-200 worker nodes.',
      ok: isIntegerInRange(form.worker_count, 0, 200),
    },
    {
      label: 'CPU / memory / disk',
      detail: 'Sizing must satisfy the current management API validation.',
      ok:
        isIntegerInRange(form.cpu_cores, 1, 64) &&
        isIntegerInRange(form.memory_mb, 512, 1048576) &&
        isIntegerInRange(form.disk_gb, 10, 8192),
    },
    {
      label: 'Bridge and VMID seed',
      detail: 'Bridge must be set and VMIDs stay within the supported range.',
      ok: typeof form.bridge === 'string' && form.bridge.trim() !== '' && isIntegerInRange(form.start_vmid, 100, 999999),
    },
  ];
}

function validateNetworkPlan(form) {
  return [
    {
      label: 'Virtual IP',
      detail: 'VIP must be a valid IPv4 address.',
      ok: isIPv4(form.vip_ip),
    },
    {
      label: 'Start IP',
      detail: 'Start IP must be a valid IPv4 address.',
      ok: isIPv4(form.start_ip),
    },
  ];
}

function isStepInputValid(stepId, form) {
  if (stepId === 'foundation-cluster-profile') {
    return validateClusterProfile(form).every((check) => check.ok);
  }
  if (stepId === 'foundation-network-plan') {
    return validateNetworkPlan(form).every((check) => check.ok);
  }
  return true;
}

function isProvisionComplete(cluster) {
  return cluster?.status === 'provisioned' || cluster?.status === 'bootstrapped';
}

function isBootstrapComplete(cluster) {
  return cluster?.status === 'bootstrapped';
}

function isCreateClusterJob(job) {
  return job?.type === 'create_cluster';
}

function isBootstrapJob(job) {
  return job?.type === 'bootstrap_cluster';
}

function isRunningJob(job) {
  return job?.status === 'pending' || job?.status === 'running';
}

function getStepStatus(step, state, previousStepsComplete) {
  const { completedStepIds, form, cluster, job } = state;
  const manualDone = completedStepIds.includes(step.id);

  switch (step.id) {
    case 'foundation-overview':
      return manualDone ? 'done' : 'ready';
    case 'foundation-cluster-profile':
      if (!previousStepsComplete) return 'locked';
      return manualDone && isStepInputValid(step.id, form) ? 'done' : 'ready';
    case 'foundation-network-plan':
      if (!previousStepsComplete) return 'locked';
      return manualDone && isStepInputValid(step.id, form) ? 'done' : 'ready';
    case 'talos-provision':
      if (!previousStepsComplete) return 'locked';
      if (isProvisionComplete(cluster)) return 'done';
      if (isCreateClusterJob(job) && job?.status === 'failed') return 'failed';
      if (isCreateClusterJob(job) && isRunningJob(job)) return 'running';
      return 'ready';
    case 'talos-bootstrap':
      if (!previousStepsComplete) return 'locked';
      if (isBootstrapComplete(cluster)) return 'done';
      if (isBootstrapJob(job) && job?.status === 'failed') return 'failed';
      if (isBootstrapJob(job) && isRunningJob(job)) return 'running';
      return Array.isArray(cluster?.controlplane_ips) && cluster.controlplane_ips.length > 0 ? 'ready' : 'blocked';
    case 'talos-validate':
      if (!previousStepsComplete) return 'locked';
      if (!cluster?.talos_config_dir) return 'blocked';
      return manualDone ? 'done' : 'ready';
    default:
      if (!previousStepsComplete) return 'locked';
      return 'blocked';
  }
}

function getStepChecks(step, state) {
  const { form, cluster, job, health, ipSuggestion } = state;

  switch (step.id) {
    case 'foundation-overview':
      return [
        {
          label: 'Management API health',
          detail: health?.ok ? 'The manager API answered successfully.' : 'Twinbox could not confirm the manager API yet.',
          status: health?.ok ? 'done' : 'blocked',
        },
        {
          label: 'Runtime baseline',
          detail: 'Management VM, web UI, API, and worker all share the same control-plane surface.',
          status: 'done',
        },
        {
          label: 'Address planning',
          detail: ipSuggestion || 'IP suggestions are optional; manual entry stays available if auto-detection fails.',
          status: ipSuggestion ? 'done' : 'ready',
        },
      ];
    case 'foundation-cluster-profile':
      return validateClusterProfile(form).map((check) => ({
        label: check.label,
        detail: check.detail,
        status: check.ok ? 'done' : 'blocked',
      }));
    case 'foundation-network-plan':
      return [
        ...validateNetworkPlan(form).map((check) => ({
          label: check.label,
          detail: check.detail,
          status: check.ok ? 'done' : 'blocked',
        })),
        {
          label: 'Suggested free range',
          detail: ipSuggestion || 'Twinbox will accept manual addresses if the automatic suggestion endpoint cannot respond.',
          status: ipSuggestion ? 'done' : 'ready',
        },
      ];
    case 'talos-provision':
      return [
        {
          label: 'Configuration draft',
          detail: 'Cluster profile and network plan must be captured before provisioning starts.',
          status: isStepInputValid('foundation-cluster-profile', form) && isStepInputValid('foundation-network-plan', form) ? 'done' : 'blocked',
        },
        {
          label: 'Provisioning job',
          detail: job?.id ? `${formatState(job.status, 'Ready')} (${job.id})` : 'No create_cluster job has been submitted yet.',
          status: isProvisionComplete(cluster)
            ? 'done'
            : isCreateClusterJob(job) && job?.status === 'failed'
              ? 'failed'
              : isCreateClusterJob(job) && isRunningJob(job)
                ? 'running'
                : 'ready',
        },
        {
          label: 'Planned node inventory',
          detail: cluster?.id
            ? `${cluster.controlplane_count ?? form.controlplane_count} control plane / ${cluster.worker_count ?? form.worker_count} worker`
            : `${form.controlplane_count} control plane / ${form.worker_count} worker`,
          status: cluster?.id ? 'done' : 'ready',
        },
      ];
    case 'talos-bootstrap':
      return [
        {
          label: 'Provisioned control planes',
          detail: (cluster?.controlplane_ips || []).join(', ') || 'Control-plane addresses will appear after provisioning succeeds.',
          status: Array.isArray(cluster?.controlplane_ips) && cluster.controlplane_ips.length > 0 ? 'done' : 'blocked',
        },
        {
          label: 'Bootstrap job',
          detail: job?.type === 'bootstrap_cluster' && job?.id ? `${formatState(job.status, 'Ready')} (${job.id})` : 'No bootstrap job has been submitted yet.',
          status: isBootstrapComplete(cluster)
            ? 'done'
            : isBootstrapJob(job) && job?.status === 'failed'
              ? 'failed'
              : isBootstrapJob(job) && isRunningJob(job)
                ? 'running'
                : 'ready',
        },
        {
          label: 'VIP and worker inventory',
          detail: cluster?.vip_ip
            ? `VIP ${cluster.vip_ip} with ${(cluster.worker_ips || []).length} worker nodes recorded.`
            : 'VIP and worker IPs will be recorded during provisioning.',
          status: cluster?.vip_ip ? 'done' : 'ready',
        },
      ];
    case 'talos-validate':
      return [
        {
          label: 'Talos config directory',
          detail: cluster?.talos_config_dir || 'Talos config directory is not available yet.',
          status: cluster?.talos_config_dir ? 'done' : 'blocked',
        },
        {
          label: 'Control-plane access',
          detail: (cluster?.controlplane_ips || []).join(', ') || 'No control-plane addresses recorded.',
          status: Array.isArray(cluster?.controlplane_ips) && cluster.controlplane_ips.length > 0 ? 'done' : 'blocked',
        },
        {
          label: 'Worker inventory',
          detail: (cluster?.worker_ips || []).join(', ') || 'No worker IPs recorded yet.',
          status: Array.isArray(cluster?.worker_ips) && cluster.worker_ips.length > 0 ? 'done' : 'ready',
        },
      ];
    default:
      return [
        {
          label: 'Execution path',
          detail: 'This phase is mapped in Mission Control, but the backend execution contract is not implemented in this build.',
          status: 'blocked',
        },
        {
          label: 'Operator visibility',
          detail: 'The operator can already see where this phase fits in the installation journey and what it will eventually govern.',
          status: 'ready',
        },
      ];
  }
}

function getArtifacts(cluster, job) {
  return [
    cluster?.id ? { label: 'Cluster ID', value: cluster.id } : null,
    job?.id ? { label: 'Active job', value: job.id } : null,
    cluster?.metadata?.proxmox_node ? { label: 'Proxmox node', value: cluster.metadata.proxmox_node } : null,
    cluster?.vip_ip ? { label: 'VIP', value: cluster.vip_ip } : null,
    (cluster?.controlplane_ips || []).length ? { label: 'Control planes', value: cluster.controlplane_ips.join(', ') } : null,
    (cluster?.worker_ips || []).length ? { label: 'Workers', value: cluster.worker_ips.join(', ') } : null,
    cluster?.talos_config_dir ? { label: 'Talos config dir', value: cluster.talos_config_dir } : null,
  ].filter(Boolean);
}

function getRisks(activeStep, state) {
  const items = [];

  if (activeStep?.risk) {
    items.push({
      label: 'Operational note',
      detail: activeStep.risk,
      tone: activeStep.kind === 'blocked' ? 'warning' : 'neutral',
    });
  }

  if (state.error) {
    items.push({
      label: 'Latest request error',
      detail: state.error,
      tone: 'danger',
    });
  }

  if (state.job?.status === 'failed' && state.job?.error) {
    items.push({
      label: 'Worker failure',
      detail: state.job.error,
      tone: 'danger',
    });
  }

  if (activeStep?.kind === 'blocked') {
    items.push({
      label: 'Current release boundary',
      detail: 'Mission Control can already describe this phase, but execution stops here until the corresponding backend capability lands.',
      tone: 'warning',
    });
  }

  return items;
}

function getEvents(activeStep, state) {
  const logEvents = (state.logs || []).slice(-6).map((entry, index) => ({
    id: `${index}-${entry.line}`,
    title: formatState(state.job?.step, 'Worker event'),
    detail: entry.line,
    tone: toneForStatus(state.job?.status),
  }));

  if (logEvents.length > 0) {
    return logEvents;
  }

  return [
    {
      id: `${activeStep.id}-summary`,
      title: formatState(activeStep.status, 'Ready'),
      detail: activeStep.summary,
      tone: toneForStatus(activeStep.status),
    },
  ];
}

function getSummaryLine(activeStep, state) {
  if (activeStep.status === 'running' && activeStep.action === 'provision') {
    return 'Twinbox is provisioning Talos nodes on Proxmox and streaming worker output into Mission Control.';
  }
  if (activeStep.status === 'running' && activeStep.action === 'bootstrap') {
    return 'Twinbox is applying Talos configuration, bootstrapping the control plane, and waiting for kubeconfig artifacts.';
  }
  if (activeStep.status === 'failed') {
    return 'The current step failed. Review the event stream and retry only after the failure mode is understood.';
  }
  if (activeStep.kind === 'blocked') {
    return 'This is the next planned platform phase. The route is visible, but execution is not wired into this build yet.';
  }
  if (activeStep.id === 'talos-validate' && state.cluster?.talos_config_dir) {
    return 'Talos bootstrap completed. Review the generated artifacts before unlocking later platform phases.';
  }
  return activeStep.summary;
}

function getPrimaryAction(activeStep, nextStep, state) {
  if (!activeStep) {
    return { type: 'none', label: 'Volgende', disabled: true, helperText: 'Geen actieve stap beschikbaar.' };
  }

  if (activeStep.kind === 'blocked') {
    return {
      type: 'none',
      label: 'Wacht op volgende release',
      disabled: true,
      helperText: 'Deze fase is zichtbaar in de reis, maar nog niet uitvoerbaar in deze build.',
    };
  }

  if (activeStep.kind === 'action') {
    if (activeStep.status === 'running') {
      return {
        type: 'none',
        label: activeStep.action === 'bootstrap' ? 'Bootstrap bezig' : 'Provisioning bezig',
        disabled: true,
        helperText: 'Twinbox werkt de huidige job af voordat de volgende stap vrijgegeven wordt.',
      };
    }
    if (activeStep.status === 'failed') {
      return {
        type: activeStep.action === 'bootstrap' ? 'retry-bootstrap' : 'retry-provision',
        label: 'Opnieuw proberen',
        disabled: state.busy,
        helperText: 'Herstart dezelfde stap pas nadat de failure details zijn beoordeeld.',
      };
    }
    if (activeStep.status === 'done') {
      return {
        type: 'advance',
        label: 'Volgende',
        disabled: !nextStep || nextStep.status === 'locked',
        helperText: nextStep?.status === 'locked' ? 'De volgende stap is nog niet beschikbaar.' : '',
      };
    }
    return {
      type: activeStep.action === 'bootstrap' ? 'bootstrap' : 'provision',
      label: activeStep.action === 'bootstrap' ? 'Bootstrap cluster' : 'Talos nodes aanmaken',
      disabled: state.busy,
      helperText: '',
    };
  }

  if (activeStep.status === 'done') {
    return {
      type: 'advance',
      label: 'Volgende',
      disabled: !nextStep || nextStep.status === 'locked',
      helperText: nextStep?.status === 'locked' ? 'De volgende stap is nog niet beschikbaar.' : '',
    };
  }

  const disabled = activeStep.kind === 'input' ? !isStepInputValid(activeStep.id, state.form) : false;
  return {
    type: 'advance',
    label: 'Volgende',
    disabled,
    helperText: disabled ? 'Vul eerst alle geldige waarden van deze stap in.' : '',
  };
}

function summarizePhase(phase, steps) {
  const completedSteps = steps.filter((step) => step.status === 'done').length;
  const running = steps.some((step) => step.status === 'running');
  const failed = steps.some((step) => step.status === 'failed');
  const blocked = steps.some((step) => step.status === 'blocked');
  const ready = steps.some((step) => step.status === 'ready');
  const status =
    completedSteps === steps.length
      ? 'done'
      : failed
        ? 'failed'
        : running
          ? 'running'
          : blocked && !ready
            ? 'blocked'
            : ready
              ? 'ready'
              : 'locked';

  const firstOutstanding = steps.find((step) => step.status !== 'done');

  return {
    ...phase,
    steps,
    completedSteps,
    totalSteps: steps.length,
    percent: Math.round((completedSteps / steps.length) * 100),
    status,
    blocker: firstOutstanding?.summary || phase.summary,
  };
}

function getHealthBadges(state) {
  const talosTone = isBootstrapComplete(state.cluster)
    ? 'success'
    : isProvisionComplete(state.cluster) || state.job?.type === 'bootstrap_cluster'
      ? 'active'
      : 'neutral';

  const dependenciesTone = isStepInputValid('foundation-network-plan', state.form)
    ? state.ipSuggestion
      ? 'success'
      : 'active'
    : 'neutral';

  return [
    {
      id: 'manager',
      label: 'Management VM',
      value: state.health?.ok ? 'Healthy' : 'Checking',
      chip: state.health?.ok ? 'API healthy' : 'Polling',
      tone: state.health?.ok ? 'success' : 'neutral',
    },
    {
      id: 'proxmox',
      label: 'Proxmox',
      value: state.cluster?.metadata?.proxmox_node || 'Configured',
      chip: state.cluster?.metadata?.proxmox_node ? 'Target selected' : 'Awaiting cluster request',
      tone: state.cluster?.metadata?.proxmox_node ? 'active' : 'neutral',
    },
    {
      id: 'talos',
      label: 'Talos',
      value: formatState(state.cluster?.status, 'Not started'),
      chip: isBootstrapComplete(state.cluster) ? 'Control plane ready' : isProvisionComplete(state.cluster) ? 'Awaiting bootstrap' : 'Pending',
      tone: talosTone,
    },
    {
      id: 'dependencies',
      label: 'Dependencies',
      value: state.ipSuggestion ? 'Prepared' : 'Manual mode',
      chip: state.ipSuggestion ? 'Subnet suggestion ready' : 'Manual network planning',
      tone: dependenciesTone,
    },
  ];
}

export function serializeMissionState(state) {
  return JSON.stringify({
    version: 1,
    form: { ...defaultForm, ...(state.form || {}) },
    completedStepIds: normalizeCompletedSteps(state.completedStepIds),
    selectedStepId: STEP_INDEX.has(state.selectedStepId) ? state.selectedStepId : 'foundation-overview',
    clusterId: typeof state.clusterId === 'string' ? state.clusterId : '',
    jobId: typeof state.jobId === 'string' ? state.jobId : '',
  });
}

export function restoreMissionState(raw) {
  try {
    const parsed = JSON.parse(raw);
    if (parsed?.version !== 1) {
      throw new Error('unsupported state version');
    }
    return {
      form: { ...defaultForm, ...(parsed.form || {}) },
      completedStepIds: normalizeCompletedSteps(parsed.completedStepIds),
      selectedStepId: STEP_INDEX.has(parsed.selectedStepId) ? parsed.selectedStepId : 'foundation-overview',
      clusterId: typeof parsed.clusterId === 'string' ? parsed.clusterId : '',
      jobId: typeof parsed.jobId === 'string' ? parsed.jobId : '',
    };
  } catch (_) {
    return {
      form: { ...defaultForm },
      completedStepIds: [],
      selectedStepId: 'foundation-overview',
      clusterId: '',
      jobId: '',
    };
  }
}

export function getMissionControlModel(input) {
  const state = {
    form: { ...defaultForm, ...(input?.form || {}) },
    completedStepIds: normalizeCompletedSteps(input?.completedStepIds),
    cluster: input?.cluster || null,
    job: input?.job || null,
    logs: Array.isArray(input?.logs) ? input.logs : [],
    health: input?.health || null,
    ipSuggestion: input?.ipSuggestion || '',
    error: input?.error || '',
    busy: Boolean(input?.busy),
  };

  let previousStepsComplete = true;
  const steps = orderedSteps.map((step) => {
    const status = getStepStatus(step, state, previousStepsComplete);
    const result = {
      ...step,
      status,
      tone: toneForStatus(status),
      checks: getStepChecks(step, state),
    };
    previousStepsComplete = previousStepsComplete && status === 'done';
    return result;
  });

  const phaseMap = new Map();
  for (const phase of phaseDefinitions) {
    const phaseSteps = steps.filter((step) => step.phaseId === phase.id);
    phaseMap.set(phase.id, summarizePhase(phase, phaseSteps));
  }

  const phases = phaseDefinitions.map((phase) => phaseMap.get(phase.id));
  const firstActionableStep = steps.find((step) => step.status !== 'done' && step.status !== 'locked') || steps[steps.length - 1];
  const selectedStep = steps.find((step) => step.id === input?.selectedStepId && step.status !== 'locked');
  const activeStep = selectedStep || firstActionableStep;
  const activeStepIndex = Math.max(STEP_INDEX.get(activeStep.id) ?? 0, 0);
  const previousStep = activeStepIndex > 0 ? steps[activeStepIndex - 1] : null;
  const nextStep = activeStepIndex < steps.length - 1 ? steps[activeStepIndex + 1] : null;
  const activePhase = phaseMap.get(activeStep.phaseId);
  const completedSteps = steps.filter((step) => step.status === 'done').length;
  const remainingEtaMinutes = steps
    .slice(activeStepIndex)
    .filter((step) => step.status !== 'done' && step.kind !== 'blocked')
    .reduce((total, step) => total + (step.etaMinutes || 0), 0);
  const primaryAction = getPrimaryAction(activeStep, nextStep, state);

  return {
    phases,
    steps,
    activeStep,
    activePhase,
    previousStep,
    nextStep,
    canAdvance: primaryAction.type === 'advance' && !primaryAction.disabled,
    primaryAction,
    progress: {
      completedSteps,
      totalSteps: steps.length,
      percent: Math.round((completedSteps / steps.length) * 100),
      phaseIndex: phaseDefinitions.findIndex((phase) => phase.id === activePhase.id) + 1,
      phaseCount: phaseDefinitions.length,
      stepIndex: activeStepIndex + 1,
      remainingEtaLabel: remainingEtaMinutes > 0 ? `~${remainingEtaMinutes} min in this release` : 'Awaiting next release',
    },
    healthBadges: getHealthBadges(state),
    activity: {
      summary: getSummaryLine(activeStep, state),
      events: getEvents(activeStep, state),
      artifacts: getArtifacts(state.cluster, state.job),
      risks: getRisks(activeStep, state),
      rawLogOutput: state.logs.length ? state.logs.map((entry) => entry.line).join('\n') : 'Nog geen technische output voor deze stap.',
    },
  };
}
