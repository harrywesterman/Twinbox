export const STORAGE_KEY = 'twinbox.catalog-ui.v1';

function fallbackCatalog() {
  return {
    categories: [],
    errors: [],
  };
}

function flattenCategories(catalog) {
  return (catalog?.categories || []).flatMap((category) =>
    (category.steps || []).map((step) => ({
      ...step,
      categoryId: category.id,
      categoryTitle: category.title,
      categorySummary: category.summary,
    })),
  );
}

function pickActiveStep(steps, selectedStepId) {
  if (selectedStepId) {
    const selected = steps.find((step) => step.id === selectedStepId);
    if (selected) return selected;
  }

  return steps.find((step) => step.status !== 'locked') || steps[0] || null;
}

function buildCategorySummaries(categories) {
  return categories.map((category) => {
    const totalSteps = category.steps.length;
    const completedSteps = category.steps.filter((step) => step.status === 'done').length;
    const percent = totalSteps ? Math.round((completedSteps / totalSteps) * 100) : 0;
    const blocker = category.steps.find((step) => step.status !== 'done')?.summary || category.summary;

    return {
      ...category,
      totalSteps,
      completedSteps,
      percent,
      blocker,
    };
  });
}

function buildProgress(steps, activeStep, categories) {
  const totalSteps = steps.length;
  const completedSteps = steps.filter((step) => step.status === 'done').length;
  const activeIndex = activeStep ? steps.findIndex((step) => step.id === activeStep.id) : -1;
  const activeCategoryIndex = activeStep
    ? categories.findIndex((category) => category.id === activeStep.categoryId)
    : -1;

  return {
    totalSteps,
    completedSteps,
    stepIndex: activeIndex >= 0 ? activeIndex + 1 : 0,
    categoryIndex: activeCategoryIndex >= 0 ? activeCategoryIndex + 1 : 0,
    categoryCount: categories.length,
    percent: totalSteps ? Math.round((completedSteps / totalSteps) * 100) : 0,
  };
}

function buildMode(steps) {
  return steps.length > 0 && steps.every((step) => step.status === 'done') ? 'manage' : 'setup';
}

function buildStepRail(steps, activeStep) {
  return steps.map((step, index) => ({
    id: step.id,
    title: step.title,
    index: index + 1,
    status: step.status,
    isCurrent: step.id === activeStep?.id,
  }));
}

function buildHealthBadges({ health, activeStep, catalogErrors, cluster }) {
  return [
    {
      id: 'health',
      label: 'Manager API',
      value: health?.ok ? 'Online' : 'Unavailable',
      chip: health?.ok ? 'Healthy' : 'Check API',
      tone: health?.ok ? 'success' : 'danger',
    },
    {
      id: 'step',
      label: 'Active step',
      value: activeStep?.title || 'No step selected',
      chip: activeStep?.status ? formatState(activeStep.status, 'Ready') : 'Idle',
      tone: toneForStatus(activeStep?.status),
    },
    {
      id: 'cluster',
      label: 'Cluster',
      value: cluster?.id || activeStep?.state?.cluster_id || 'Not created',
      chip: cluster?.status ? formatState(cluster.status, 'Pending') : 'Awaiting run',
      tone: cluster?.status === 'bootstrapped' ? 'success' : cluster?.status ? 'active' : 'neutral',
    },
    {
      id: 'catalog',
      label: 'Catalog',
      value: `${catalogErrors.length} issues`,
      chip: catalogErrors.length ? 'Needs review' : 'Validated',
      tone: catalogErrors.length ? 'warning' : 'success',
    },
  ];
}

function buildArtifacts(activeStep, cluster) {
  const artifacts = [];

  if (cluster?.id) {
    artifacts.push({ label: 'Cluster ID', value: cluster.id });
  }

  if (activeStep?.state?.cluster_id) {
    artifacts.push({ label: 'Cluster ID', value: activeStep.state.cluster_id });
  }

  if (cluster?.status) {
    artifacts.push({ label: 'Cluster status', value: formatState(cluster.status, 'Unknown') });
  }

  if (cluster?.vip_ip) {
    artifacts.push({ label: 'VIP', value: cluster.vip_ip });
  }

  if ((cluster?.controlplane_ips || []).length) {
    artifacts.push({ label: 'Control planes', value: cluster.controlplane_ips.join(', ') });
  }

  if ((cluster?.worker_ips || []).length) {
    artifacts.push({ label: 'Workers', value: cluster.worker_ips.join(', ') });
  }

  if (cluster?.talos_config_dir) {
    artifacts.push({ label: 'Talos config', value: cluster.talos_config_dir });
  }

  if (activeStep?.state?.outputs && typeof activeStep.state.outputs === 'object') {
    for (const [label, value] of Object.entries(activeStep.state.outputs)) {
      if (value === null || value === undefined || label === 'cluster_id') continue;
      artifacts.push({
        label: formatState(label, label),
        value: typeof value === 'boolean' ? (value ? 'Enabled' : 'Disabled') : String(value),
      });
    }
  }

  return artifacts;
}

function parseLoggedAt(line) {
  if (typeof line !== 'string') return null;
  const match = line.match(/^\[([^\]]+)\]\s*/);
  if (!match) return null;
  const parsed = new Date(match[1]);
  if (Number.isNaN(parsed.getTime())) return null;
  return parsed;
}

function stripLogTimestamp(line) {
  if (typeof line !== 'string') return '';
  return line.replace(/^\[[^\]]+\]\s*/, '');
}

function summarizeStage(detail, activeStep) {
  const normalized = detail.toLowerCase();

  if (normalized.includes('queued run_step') || normalized.includes('queued bootstrap_cluster') || normalized.includes('queued create_cluster')) {
    return { title: 'Queued', tone: 'neutral' };
  }
  if (normalized.includes('running job type=')) {
    return { title: 'Starting step', tone: 'active' };
  }
  if (normalized.includes('created controlplane vm') || normalized.includes('created worker vm')) {
    return { title: 'Creating VMs', tone: 'active' };
  }
  if (normalized.includes('generating talos config')) {
    return { title: 'Preparing Talos', tone: 'active' };
  }
  if (normalized.includes('applying controlplane config') || normalized.includes('applying worker config')) {
    return { title: 'Applying configuration', tone: 'active' };
  }
  if (normalized.includes('bootstrapping cluster')) {
    return { title: 'Bootstrapping cluster', tone: 'active' };
  }
  if (normalized.includes('generating kubeconfig')) {
    return { title: 'Fetching kubeconfig', tone: 'active' };
  }
  if (normalized.includes('detaching talos iso')) {
    return { title: 'Cleaning up', tone: 'active' };
  }
  if (normalized.includes('job completed')) {
    return { title: 'Done', tone: 'success' };
  }
  if (normalized.includes('job failed:')) {
    return { title: 'Failed', tone: 'danger' };
  }

  return {
    title: activeStep?.title || 'Step event',
    tone: 'active',
  };
}

function formatElapsedFrom(date) {
  if (!(date instanceof Date) || Number.isNaN(date.getTime())) {
    return 'Updated recently';
  }

  const seconds = Math.max(0, Math.round((Date.now() - date.getTime()) / 1000));
  if (seconds <= 1) return 'Updated just now';
  return `Updated ${seconds}s ago`;
}

function fallbackRuntimeEvent(activeStep, latestJob) {
  const status = latestJob?.status || activeStep?.status || 'ready';
  if (status === 'pending') {
    return {
      id: `${activeStep?.id || 'step'}-queued`,
      title: 'Queued',
      detail: 'Twinbox queued this step and is waiting for the worker.',
      tone: 'neutral',
      timestamp: null,
    };
  }
  if (status === 'running') {
    return {
      id: `${activeStep?.id || 'step'}-running`,
      title: 'Running',
      detail: 'Twinbox is executing the selected step.',
      tone: 'active',
      timestamp: null,
    };
  }
  if (status === 'failed') {
    return {
      id: `${activeStep?.id || 'step'}-failed`,
      title: 'Failed',
      detail: latestJob?.error || activeStep?.state?.error || 'The latest run failed.',
      tone: 'danger',
      timestamp: null,
    };
  }
  if (status === 'succeeded' || status === 'done') {
    return {
      id: `${activeStep?.id || 'step'}-done`,
      title: 'Done',
      detail: 'The latest run completed successfully.',
      tone: 'success',
      timestamp: null,
    };
  }

  return {
    id: `${activeStep?.id || 'step'}-idle`,
    title: 'Ready',
    detail: 'Run the selected step to stream worker output here.',
    tone: 'neutral',
    timestamp: null,
  };
}

function buildRuntime(logs, activeStep) {
  const latestJob = activeStep?.latest_job || null;
  const parsedEvents = (Array.isArray(logs) ? logs : [])
    .filter((entry) => entry?.line)
    .map((entry, index) => {
      const detail = stripLogTimestamp(entry.line);
      const stage = summarizeStage(detail, activeStep);
      return {
        id: `${activeStep?.id || 'step'}-${index}`,
        title: stage.title,
        detail,
        tone: stage.tone,
        timestamp: parseLoggedAt(entry.line),
      };
    });

  const timelineEvents = parsedEvents.length > 0 ? parsedEvents : [fallbackRuntimeEvent(activeStep, latestJob)];
  const currentEvent = timelineEvents.at(-1);
  const currentStage = currentEvent?.title || formatState(latestJob?.status || activeStep?.status, 'Ready');
  const runState = latestJob?.status || activeStep?.status || 'ready';
  const latestTimestamp = currentEvent?.timestamp || (latestJob?.updated_at ? new Date(latestJob.updated_at) : null);
  const lastUpdatedLabel = formatElapsedFrom(latestTimestamp);
  const staleSeconds = latestTimestamp instanceof Date && !Number.isNaN(latestTimestamp.getTime())
    ? Math.max(0, Math.round((Date.now() - latestTimestamp.getTime()) / 1000))
    : 0;

  return {
    currentStage,
    runState,
    lastUpdatedLabel,
    isLive: runState === 'running' || runState === 'pending',
    isStale: (runState === 'running' || runState === 'pending') && staleSeconds >= 30,
    eventCount: timelineEvents.length,
    timelineEvents,
  };
}

function buildEvents(runtime) {
  if (runtime?.timelineEvents?.length) {
    return runtime.timelineEvents;
  }

  return [
    {
      id: 'no-events',
      title: 'No live events yet',
      detail: 'Run the selected step to stream worker output here.',
      tone: 'neutral',
      timestamp: null,
    },
  ];
}

function buildRisks(activeStep, catalogErrors, error) {
  const risks = [];

  if (activeStep?.status === 'locked') {
    risks.push({
      label: 'Dependencies incomplete',
      detail: 'Complete the prerequisite steps before this step can run.',
      tone: 'warning',
    });
  }

  if (activeStep?.state?.error) {
    risks.push({
      label: 'Last execution failed',
      detail: activeStep.state.error,
      tone: 'danger',
    });
  }

  if (error) {
    risks.push({
      label: 'Latest request failed',
      detail: error,
      tone: 'danger',
    });
  }

  if (catalogErrors.length) {
    risks.push({
      label: 'Catalog validation issues',
      detail: catalogErrors.join(' | '),
      tone: 'warning',
    });
  }

  if (risks.length === 0) {
    risks.push({
      label: 'No blocking risks',
      detail: activeStep?.side_help || 'The current step is ready to execute.',
      tone: 'neutral',
    });
  }

  return risks;
}

function buildPrimaryAction(activeStep, nextStep, busy, stepIndex, mode) {
  if (!activeStep) {
    return {
      type: 'noop',
      label: 'No step selected',
      disabled: true,
      helperText: '',
    };
  }

  if (busy || activeStep.status === 'running') {
    return {
      type: 'execute',
      label: 'Running…',
      disabled: true,
      helperText: 'Twinbox is waiting for the current worker job to finish.',
    };
  }

  if (activeStep.status === 'locked') {
    return {
      type: 'execute',
      label: 'Blocked',
      disabled: true,
      helperText: 'Complete the dependency chain before running this step.',
    };
  }

  if (activeStep.status === 'done' && nextStep) {
    return {
      type: 'advance',
      label: mode === 'setup' ? `Continue to step ${stepIndex + 1}` : 'Next',
      disabled: false,
      helperText: 'This step is complete. Continue to the next unlocked step.',
    };
  }

  const rerun = activeStep.status === 'failed' || activeStep.status === 'done';
  return {
    type: 'execute',
    label: mode === 'setup'
      ? (rerun ? `Retry step ${stepIndex}` : `Start step ${stepIndex}`)
      : (rerun ? 'Run again' : 'Run step'),
    disabled: false,
    helperText: activeStep.type === 'config'
      ? 'Save the configuration and apply it on the Management VM.'
      : 'Execute the selected step and stream the worker output live.',
  };
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
  if (value === 'locked' || value === 'warning') return 'warning';
  return 'neutral';
}

export function isIPv4(value) {
  if (typeof value !== 'string') return false;
  const parts = value.split('.');
  if (parts.length !== 4) return false;
  return parts.every((part) => /^\d+$/.test(part) && Number(part) >= 0 && Number(part) <= 255);
}

export function serializeUiState({ selectedStepId }) {
  return JSON.stringify({
    selectedStepId: typeof selectedStepId === 'string' ? selectedStepId : '',
  });
}

export function restoreUiState(value) {
  if (!value) return { selectedStepId: '' };
  try {
    const parsed = JSON.parse(value);
    return {
      selectedStepId: typeof parsed.selectedStepId === 'string' ? parsed.selectedStepId : '',
    };
  } catch {
    return { selectedStepId: '' };
  }
}

export function getMissionControlModel({
  catalog,
  selectedStepId,
  logs,
  cluster,
  health,
  error,
  busy,
}) {
  const safeCatalog = catalog || fallbackCatalog();
  const categories = buildCategorySummaries(safeCatalog.categories || []);
  const steps = flattenCategories({ categories });
  const activeStep = pickActiveStep(steps, selectedStepId);
  const activeCategory = activeStep
    ? categories.find((category) => category.id === activeStep.categoryId)
    : null;
  const activeIndex = activeStep ? steps.findIndex((step) => step.id === activeStep.id) : -1;
  const previousStep = activeIndex > 0 ? steps[activeIndex - 1] : null;
  const nextStep = activeIndex >= 0 && activeIndex < steps.length - 1 ? steps[activeIndex + 1] : null;
  const progress = buildProgress(steps, activeStep, categories);
  const catalogErrors = safeCatalog.errors || [];
  const runtime = buildRuntime(logs, activeStep);
  const mode = buildMode(steps);
  const stepRail = buildStepRail(steps, activeStep);

  return {
    categories,
    steps,
    mode,
    stepRail,
    activeCategory,
    activeStep,
    previousStep,
    nextStep,
    progress,
    healthBadges: buildHealthBadges({ health, activeStep, catalogErrors, cluster }),
    primaryAction: buildPrimaryAction(activeStep, nextStep, busy, progress.stepIndex, mode),
    activity: {
      summary: activeStep?.summary || 'Catalog data is not available yet.',
      artifacts: buildArtifacts(activeStep, cluster),
      runtime,
      events: buildEvents(runtime),
      risks: buildRisks(activeStep, catalogErrors, error),
      rawLogOutput: Array.isArray(logs) && logs.length ? logs.map((entry) => entry.line).join('\n') : 'No worker output yet.',
    },
  };
}
