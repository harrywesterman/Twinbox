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

function buildEvents(logs, activeStep) {
  const recentLogs = Array.isArray(logs) ? logs.slice(-6) : [];
  if (recentLogs.length > 0) {
    return recentLogs.map((entry, index) => ({
      id: `${activeStep?.id || 'step'}-${index}`,
      title: activeStep?.title || 'Step event',
      detail: entry.line,
      tone: 'active',
    }));
  }

  return [
    {
      id: 'no-events',
      title: 'No live events yet',
      detail: 'Run the selected step to stream worker output here.',
      tone: 'neutral',
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

function buildPrimaryAction(activeStep, nextStep, busy) {
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
      label: 'Next',
      disabled: false,
      helperText: 'This step is complete. Continue to the next unlocked step.',
    };
  }

  const rerun = activeStep.status === 'failed' || activeStep.status === 'done';
  return {
    type: 'execute',
    label: rerun ? 'Run again' : 'Run step',
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

  return {
    categories,
    steps,
    activeCategory,
    activeStep,
    previousStep,
    nextStep,
    progress,
    healthBadges: buildHealthBadges({ health, activeStep, catalogErrors, cluster }),
    primaryAction: buildPrimaryAction(activeStep, nextStep, busy),
    activity: {
      summary: activeStep?.summary || 'Catalog data is not available yet.',
      artifacts: buildArtifacts(activeStep, cluster),
      events: buildEvents(logs, activeStep),
      risks: buildRisks(activeStep, catalogErrors, error),
      rawLogOutput: Array.isArray(logs) && logs.length ? logs.map((entry) => entry.line).join('\n') : 'No worker output yet.',
    },
  };
}
