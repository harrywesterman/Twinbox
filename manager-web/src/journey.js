import { resolveStepPresentation } from "./step-presentation.js";
import { normalizeLogEntries } from "./install-logs.js";

export const STORAGE_KEY = "twinbox.installation-wizard.v1";

function fallbackCatalog() {
  return {
    categories: [],
    errors: [],
  };
}

const FIXED_SETUP_STEP_IDS = [
  "provision-nodes",
  "install-argocd",
  "install-longhorn-storage",
  "install-secret-sync",
  "install-crowdsec",
  "install-traefik",
  "install-cloudnativepg",
  "configure-dns",
  "choose-ingress-route",
  "install-authentik-idp",
  "create-users-and-groups",
  "provision-netbird-bastion",
  "configure-cloudflare-tunnel",
  "configure-netbird-ingress",
  "install-netbird-routing-peers",
  "configure-netbird-admin-access",
  "install-adguard",
  "configure-argocd-oidc",
  "install-headlamp",
  "install-prometheus",
  "install-loki",
  "install-tempo",
  "install-alloy",
  "install-grafana",
  "install-beszel",
  "install-dashy-dashboard",
  "install-twinbox-portal",
  "install-management-consoles",
  "install-pgadmin4",
  "install-ntfy",
  "install-velero-backup",
  "install-velero-ui",
  "install-management-backup",
];

const FIXED_SETUP_ORDER = new Map(FIXED_SETUP_STEP_IDS.map((id, index) => [id, index]));

function matchesSelectedIngressRoute(step, answers = {}) {
  if (!step?.ingress_route) {
    return true;
  }

  const selectedRoute = answers?.["choose-ingress-route"]?.ingress_route || "";
  return step.ingress_route === selectedRoute;
}

function flattenSetupSteps(catalog, answers = {}) {
  return (catalog?.categories || [])
    .flatMap((category) =>
      (category.steps || [])
        .filter((step) => step?.journey_stage !== "manage")
        .filter((step) => FIXED_SETUP_ORDER.has(step?.id))
        .filter((step) => matchesSelectedIngressRoute(step, answers))
        .map((step) => ({
          ...step,
          ...resolveStepPresentation(step),
          categoryId: category.id,
          categoryTitle: category.title,
          categorySummary: category.summary,
        }))
    )
    .sort((left, right) => FIXED_SETUP_ORDER.get(left.id) - FIXED_SETUP_ORDER.get(right.id));
}

function isComplete(step) {
  return step?.status === "done" || step?.status === "configured" || step?.status === "skipped";
}

function pickActiveStep(steps, selectedStepId) {
  if (selectedStepId) {
    const selected = steps.find((step) => step.id === selectedStepId);
    if (selected) return selected;
  }

  return steps[0] || null;
}

function buildProgress(steps, activeStep) {
  const totalSteps = steps.length;
  const completedSteps = steps.filter(isComplete).length;
  const skippedSteps = steps.filter((step) => step.status === "skipped").length;
  const activeIndex = activeStep ? steps.findIndex((step) => step.id === activeStep.id) : -1;

  return {
    totalSteps,
    completedSteps,
    skippedSteps,
    remainingSteps: Math.max(0, totalSteps - completedSteps),
    stepIndex: activeIndex >= 0 ? activeIndex + 1 : 0,
    percent: totalSteps ? Math.round((completedSteps / totalSteps) * 100) : 0,
  };
}

function buildMode(steps) {
  return steps.length > 0 && steps.every(isComplete) ? "manage" : "setup";
}

function buildStepRail(steps, activeStep) {
  return steps.map((step, index) => ({
    id: step.id,
    title: step.title,
    icon: step.icon,
    index: index + 1,
    status: step.status,
    isCurrent: step.id === activeStep?.id,
    isComplete: isComplete(step),
    isSkipped: step.status === "skipped",
    project_url: step.project_url,
    github_url: step.github_url,
    positive_summary: step.positive_summary,
  }));
}

function buildHealthBadges({ health, activeStep, catalogErrors, cluster, mode }) {
  return [
    {
      id: "health",
      label: "API health",
      value: health?.ok ? "Online" : "Unavailable",
      chip: health?.ok ? "Healthy" : "Check API",
      tone: health?.ok ? "success" : "danger",
    },
    {
      id: "mode",
      label: "Wizard mode",
      value: mode === "setup" ? "Guided install" : "Finished",
      chip: mode === "setup" ? "Setup" : "Complete",
      tone: mode === "setup" ? "active" : "success",
    },
    {
      id: "step",
      label: "Active step",
      value: activeStep?.title || "No step selected",
      chip: activeStep?.status ? formatState(activeStep.status, "Ready") : "Idle",
      tone: toneForStatus(activeStep?.status),
    },
    {
      id: "cluster",
      label: "Cluster",
      value: cluster?.id || activeStep?.state?.cluster_id || "Not created yet",
      chip: cluster?.status ? formatState(cluster.status, "Pending") : "Waiting",
      tone: cluster?.status === "bootstrapped" ? "success" : cluster?.status ? "active" : "neutral",
    },
    {
      id: "catalog",
      label: "Catalog",
      value: `${catalogErrors.length} issue${catalogErrors.length === 1 ? "" : "s"}`,
      chip: catalogErrors.length ? "Needs review" : "Validated",
      tone: catalogErrors.length ? "warning" : "success",
    },
  ];
}

function buildArtifacts(activeStep, cluster) {
  const artifacts = [];
  const seen = new Set();

  const pushArtifact = (label, value) => {
    const signature = `${label}:${value}`;
    if (seen.has(signature)) {
      return;
    }
    seen.add(signature);
    artifacts.push({ label, value });
  };

  if (cluster?.id) {
    pushArtifact("Cluster ID", cluster.id);
  }

  if (activeStep?.state?.cluster_id) {
    pushArtifact("Cluster ID", activeStep.state.cluster_id);
  }

  if (cluster?.status) {
    pushArtifact("Cluster status", formatState(cluster.status, "Unknown"));
  }

  if (cluster?.vip_ip) {
    pushArtifact("VIP", cluster.vip_ip);
  }

  if ((cluster?.controlplane_ips || []).length) {
    pushArtifact("Control planes", cluster.controlplane_ips.join(", "));
  }

  if ((cluster?.worker_ips || []).length) {
    pushArtifact("Workers", cluster.worker_ips.join(", "));
  }

  if (cluster?.talos_config_dir) {
    pushArtifact("Talos config", cluster.talos_config_dir);
  }

  if (cluster?.kubeconfig_path) {
    pushArtifact("Kubeconfig", cluster.kubeconfig_path);
  }

  if (cluster?.iac?.state_path) {
    pushArtifact("OpenTofu state", cluster.iac.state_path);
  }

  if (cluster?.iac?.workdir) {
    pushArtifact("OpenTofu workdir", cluster.iac.workdir);
  }

  if (activeStep?.state?.outputs && typeof activeStep.state.outputs === "object") {
    for (const [label, value] of Object.entries(activeStep.state.outputs)) {
      if (value === null || value === undefined || label === "cluster_id") continue;
      pushArtifact(
        formatState(label, label),
        typeof value === "boolean" ? (value ? "Enabled" : "Disabled") : String(value)
      );
    }
  }

  return artifacts;
}

function parseLoggedAt(line) {
  if (typeof line !== "string") return null;
  const match = line.match(/^\[([^\]]+)\]\s*/);
  if (!match) return null;
  const parsed = new Date(match[1]);
  if (Number.isNaN(parsed.getTime())) return null;
  return parsed;
}

function stripLogTimestamp(line) {
  if (typeof line !== "string") return "";
  return line.replace(/^\[[^\]]+\]\s*/, "");
}

function summarizeStage(detail, activeStep) {
  const normalized = detail.toLowerCase();

  if (
    normalized.includes("queued run_step") ||
    normalized.includes("queued bootstrap_cluster") ||
    normalized.includes("queued create_cluster") ||
    normalized.includes("queued apply_cluster")
  ) {
    return { title: "Queued", tone: "neutral" };
  }
  if (normalized.includes("running job type=")) {
    return { title: "Starting step", tone: "active" };
  }
  if (normalized.includes("resolving talos image")) {
    return { title: "Resolving image", tone: "active" };
  }
  if (normalized.includes("preparing opentofu module")) {
    return { title: "Preparing OpenTofu", tone: "active" };
  }
  if (normalized.includes("generating nocloud artifacts")) {
    return { title: "Preparing NoCloud", tone: "active" };
  }
  if (normalized.includes("applying opentofu cluster plan")) {
    return { title: "Applying cluster plan", tone: "active" };
  }
  if (normalized.includes("created controlplane vm") || normalized.includes("created worker vm")) {
    return { title: "Creating VMs", tone: "active" };
  }
  if (normalized.includes("generating talos config")) {
    return { title: "Preparing Talos", tone: "active" };
  }
  if (
    normalized.includes("applying controlplane config") ||
    normalized.includes("applying worker config")
  ) {
    return { title: "Applying configuration", tone: "active" };
  }
  if (normalized.includes("bootstrapping cluster")) {
    return { title: "Bootstrapping cluster", tone: "active" };
  }
  if (normalized.includes("generating kubeconfig")) {
    return { title: "Fetching kubeconfig", tone: "active" };
  }
  if (normalized.includes("collecting opentofu outputs")) {
    return { title: "Collecting outputs", tone: "active" };
  }
  if (normalized.includes("detaching talos iso")) {
    return { title: "Cleaning up", tone: "active" };
  }
  if (normalized.includes("cluster apply completed")) {
    return { title: "Done", tone: "success" };
  }
  if (normalized.includes("job completed")) {
    return { title: "Done", tone: "success" };
  }
  if (normalized.includes("job failed:")) {
    return { title: "Failed", tone: "danger" };
  }

  return {
    title: activeStep?.title || "Step event",
    tone: "active",
  };
}

function formatElapsedFrom(date) {
  if (!(date instanceof Date) || Number.isNaN(date.getTime())) {
    return "Updated recently";
  }

  const seconds = Math.max(0, Math.round((Date.now() - date.getTime()) / 1000));
  if (seconds <= 1) return "Updated just now";
  return `Updated ${seconds}s ago`;
}

function fallbackRuntimeEvent(activeStep, latestJob) {
  const status = latestJob?.status || activeStep?.status || "ready";
  if (status === "pending") {
    return {
      id: `${activeStep?.id || "step"}-queued`,
      title: "Queued",
      detail: "Twinbox queued this step and is waiting for the worker.",
      tone: "neutral",
      timestamp: null,
    };
  }
  if (status === "running") {
    return {
      id: `${activeStep?.id || "step"}-running`,
      title: "Running",
      detail: "Twinbox is executing the selected step.",
      tone: "active",
      timestamp: null,
    };
  }
  if (status === "failed") {
    return {
      id: `${activeStep?.id || "step"}-failed`,
      title: "Failed",
      detail: latestJob?.error || activeStep?.state?.error || "The latest run failed.",
      tone: "danger",
      timestamp: null,
    };
  }
  if (status === "succeeded" || status === "done" || status === "configured") {
    return {
      id: `${activeStep?.id || "step"}-done`,
      title: "Done",
      detail: "The latest run completed successfully.",
      tone: "success",
      timestamp: null,
    };
  }
  if (status === "skipped") {
    return {
      id: `${activeStep?.id || "step"}-skipped`,
      title: "Skipped",
      detail: "This step was skipped.",
      tone: "warning",
      timestamp: null,
    };
  }

  return {
    id: `${activeStep?.id || "step"}-idle`,
    title: "Ready",
    detail: "Run the selected step to stream worker output here.",
    tone: "neutral",
    timestamp: null,
  };
}

function groupTimelineEvents(events) {
  const grouped = [];
  let currentGroup = null;

  for (const event of events) {
    const eventTime =
      event.timestamp instanceof Date && !Number.isNaN(event.timestamp.getTime())
        ? event.timestamp
        : null;
    const lastTime =
      currentGroup?.timestamp instanceof Date && !Number.isNaN(currentGroup.timestamp.getTime())
        ? currentGroup.timestamp
        : null;
    const sameStage =
      currentGroup && currentGroup.title === event.title && currentGroup.tone === event.tone;
    const closeEnough =
      sameStage && eventTime && lastTime
        ? Math.abs(eventTime.getTime() - lastTime.getTime()) <= 5000
        : sameStage;

    if (!currentGroup || !closeEnough) {
      currentGroup = {
        id: event.id,
        title: event.title,
        tone: event.tone,
        timestamp: event.timestamp,
        detailLines: [event.detail],
        detail: event.detail,
      };
      grouped.push(currentGroup);
      continue;
    }

    currentGroup.detailLines.push(event.detail);
    currentGroup.detail = currentGroup.detailLines.join("\n");
    if (!currentGroup.timestamp && event.timestamp) {
      currentGroup.timestamp = event.timestamp;
    }
  }

  return grouped.map((group, index) => ({
    ...group,
    id: `${group.id}-group-${index}`,
    lineCount: group.detailLines.length,
    detail:
      group.detailLines.length > 1
        ? `${group.detailLines[0]}\n… ${group.detailLines.length - 1} more line${group.detailLines.length === 2 ? "" : "s"}`
        : group.detailLines[0],
  }));
}

function buildRuntime(logs, activeStep) {
  const latestJob = activeStep?.latest_job || null;
  const normalizedLogs = normalizeLogEntries(logs);
  const parsedEvents = normalizedLogs.map((line, index) => {
    const detail = stripLogTimestamp(line);
    const stage = summarizeStage(detail, activeStep);
    return {
      id: `${activeStep?.id || "step"}-${index}`,
      title: stage.title,
      detail,
      tone: stage.tone,
      timestamp: parseLoggedAt(line),
    };
  });

  const timelineEvents =
    parsedEvents.length > 0
      ? groupTimelineEvents(parsedEvents)
      : [fallbackRuntimeEvent(activeStep, latestJob)];
  const currentEvent = timelineEvents.at(-1);
  const currentStage =
    currentEvent?.title || formatState(latestJob?.status || activeStep?.status, "Ready");
  const runState = latestJob?.status || activeStep?.status || "ready";
  const latestTimestamp =
    currentEvent?.timestamp || (latestJob?.updated_at ? new Date(latestJob.updated_at) : null);
  const lastUpdatedLabel = formatElapsedFrom(latestTimestamp);
  const staleSeconds =
    latestTimestamp instanceof Date && !Number.isNaN(latestTimestamp.getTime())
      ? Math.max(0, Math.round((Date.now() - latestTimestamp.getTime()) / 1000))
      : 0;

  return {
    currentStage,
    runState,
    lastUpdatedLabel,
    isLive: runState === "running" || runState === "pending",
    isStale: (runState === "running" || runState === "pending") && staleSeconds >= 30,
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
      id: "no-events",
      title: "No live events yet",
      detail: "Run the selected step to stream worker output here.",
      tone: "neutral",
      timestamp: null,
    },
  ];
}

function buildRisks(activeStep, catalogErrors, error) {
  const risks = [];

  if (activeStep?.status === "skipped") {
    risks.push({
      label: "Step skipped",
      detail: 'This step was skipped. Use "Run this step" to execute it.',
      tone: "warning",
    });
  }

  if (activeStep?.state?.error) {
    risks.push({
      label: "Last execution failed",
      detail: activeStep.state.error,
      tone: "danger",
    });
  }

  if (error) {
    risks.push({
      label: "Latest request failed",
      detail: error,
      tone: "danger",
    });
  }

  if (catalogErrors.length) {
    risks.push({
      label: "Catalog validation issues",
      detail: catalogErrors.join(" | "),
      tone: "warning",
    });
  }

  if (risks.length === 0) {
    risks.push({
      label: "No blocking risks",
      detail: activeStep?.side_help || "The current step is ready to execute.",
      tone: "neutral",
    });
  }

  return risks;
}

function buildPrimaryAction(activeStep, nextStep, _busy, _stepIndex, _mode) {
  if (!activeStep) {
    return {
      type: "noop",
      label: "No step selected",
      disabled: true,
      helperText: "",
    };
  }

  if (activeStep.status === "running") {
    return {
      type: "execute",
      label: "Working…",
      disabled: true,
      helperText: "This step is currently running. Monitor the live output below.",
    };
  }

  // Allow browsing and configuring other steps even while something is running.
  // Only disable the execute button if this specific step is busy.

  if (activeStep.status === "skipped") {
    return {
      type: "unskip",
      label: "Run this step",
      disabled: false,
      helperText: "This step was skipped. Click to run it now.",
    };
  }

  if (isComplete(activeStep) && nextStep) {
    return {
      type: "advance",
      label: "Next",
      disabled: false,
      helperText: "This step is complete. Continue to the next step.",
    };
  }

  if (isComplete(activeStep) && !nextStep) {
    return {
      type: "finish",
      label: "Finish",
      disabled: false,
      helperText: "Everything is complete. Review the summary or export the answers file.",
    };
  }

  const rerun = activeStep.status === "failed";
  return {
    type: "execute",
    label: rerun ? "Retry" : "Next",
    disabled: false,
    helperText:
      activeStep.type === "config"
        ? "Save the configuration and apply it on the Management VM."
        : "Execute the selected step and stream the worker output live.",
  };
}

function buildCompletion(activeStep, progress, cluster) {
  const clusterIdentity =
    cluster?.id ||
    cluster?.slug ||
    activeStep?.state?.cluster_id ||
    activeStep?.state?.outputs?.cluster_id ||
    "";

  return {
    title: clusterIdentity ? "Cluster bootstrap complete" : "Setup complete",
    summary: clusterIdentity
      ? "The cluster is provisioned and the wizard answers are ready to export."
      : "All setup steps are complete. Export the answers file or review the final output.",
    stepTitle: activeStep?.title || "Final step",
    completedSteps: progress.completedSteps,
    totalSteps: progress.totalSteps,
  };
}

export function formatState(value, fallback) {
  if (!value) return fallback;
  return value
    .toString()
    .replace(/[_-]+/g, " ")
    .replace(/\b\w/g, (char) => char.toUpperCase());
}

export function toneForStatus(value) {
  if (value === "done" || value === "configured" || value === "success") return "success";
  if (value === "skipped") return "warning";
  if (value === "running" || value === "ready" || value === "active") return "active";
  if (value === "canceled") return "warning";
  if (value === "failed" || value === "danger") return "danger";
  if (value === "warning") return "warning";
  return "neutral";
}

export function serializeUiState({
  selectedStepId = "",
  wizardPhase = "questions",
  answers = {},
  clusterId = "",
  clusterCreatedAt = "",
  clusterInstanceId = "",
  installLogSnapshot = { stepId: "", output: "" },
} = {}) {
  return JSON.stringify({
    version: 1,
    selectedStepId: typeof selectedStepId === "string" ? selectedStepId : "",
    wizardPhase: wizardPhase === "install" ? "install" : "questions",
    clusterId: typeof clusterId === "string" ? clusterId : "",
    clusterCreatedAt: typeof clusterCreatedAt === "string" ? clusterCreatedAt : "",
    clusterInstanceId: typeof clusterInstanceId === "string" ? clusterInstanceId : "",
    answers: answers && typeof answers === "object" ? answers : {},
    installLogSnapshot:
      installLogSnapshot && typeof installLogSnapshot === "object"
        ? {
            stepId: typeof installLogSnapshot.stepId === "string" ? installLogSnapshot.stepId : "",
            output: typeof installLogSnapshot.output === "string" ? installLogSnapshot.output : "",
          }
        : { stepId: "", output: "" },
  });
}

function sanitizeFilenameSegment(value) {
  const normalized = String(value || "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");

  return normalized || "";
}

export function buildWizardExportFilename({
  clusterName = "",
  clusterId = "",
  date = new Date(),
} = {}) {
  const dateStamp =
    date instanceof Date && !Number.isNaN(date.getTime())
      ? date.toISOString().slice(0, 10)
      : new Date().toISOString().slice(0, 10);
  const clusterLabel =
    sanitizeFilenameSegment(clusterName) || sanitizeFilenameSegment(clusterId) || "cluster";

  return `twinbox-${clusterLabel}-${dateStamp}.json`;
}

export function restoreUiState(value) {
  if (!value) {
    return {
      selectedStepId: "",
      wizardPhase: "",
      clusterId: "",
      clusterCreatedAt: "",
      clusterInstanceId: "",
      answers: {},
      installLogSnapshot: { stepId: "", output: "" },
    };
  }

  try {
    const parsed = JSON.parse(value);
    return {
      selectedStepId: typeof parsed.selectedStepId === "string" ? parsed.selectedStepId : "",
      wizardPhase: typeof parsed.wizardPhase === "string" ? parsed.wizardPhase : "",
      clusterId: typeof parsed.clusterId === "string" ? parsed.clusterId : "",
      clusterCreatedAt: typeof parsed.clusterCreatedAt === "string" ? parsed.clusterCreatedAt : "",
      clusterInstanceId:
        typeof parsed.clusterInstanceId === "string" ? parsed.clusterInstanceId : "",
      answers: parsed.answers && typeof parsed.answers === "object" ? parsed.answers : {},
      installLogSnapshot:
        parsed.installLogSnapshot && typeof parsed.installLogSnapshot === "object"
          ? {
              stepId:
                typeof parsed.installLogSnapshot.stepId === "string"
                  ? parsed.installLogSnapshot.stepId
                  : "",
              output:
                typeof parsed.installLogSnapshot.output === "string"
                  ? parsed.installLogSnapshot.output
                  : "",
            }
          : { stepId: "", output: "" },
    };
  } catch {
    return {
      selectedStepId: "",
      wizardPhase: "",
      clusterId: "",
      clusterCreatedAt: "",
      clusterInstanceId: "",
      answers: {},
      installLogSnapshot: { stepId: "", output: "" },
    };
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
  answers = {},
}) {
  const safeCatalog = catalog || fallbackCatalog();
  const steps = flattenSetupSteps(safeCatalog, answers);
  const mode = buildMode(steps);
  const activeStep = pickActiveStep(steps, selectedStepId);
  const activeIndex = activeStep ? steps.findIndex((step) => step.id === activeStep.id) : -1;
  const nextStep =
    activeIndex >= 0 && activeIndex < steps.length - 1 ? steps[activeIndex + 1] : null;
  const previousStep = activeIndex > 0 ? steps[activeIndex - 1] : null;
  const progress = buildProgress(steps, activeStep);
  const catalogErrors = safeCatalog.errors || [];
  const runtime = buildRuntime(logs, activeStep);
  const stepRail = buildStepRail(steps, activeStep);

  return {
    mode,
    steps,
    stepRail,
    activeStep,
    previousStep,
    nextStep,
    progress,
    healthBadges: buildHealthBadges({ health, activeStep, catalogErrors, cluster, mode }),
    primaryAction: buildPrimaryAction(activeStep, nextStep, busy, progress.stepIndex, mode),
    activity: {
      summary: activeStep?.summary || "Catalog data is not available yet.",
      explanation: activeStep?.side_help || "",
      sideHelp: activeStep?.explanation || "",
      artifacts: buildArtifacts(activeStep, cluster),
      runtime,
      events: buildEvents(runtime),
      risks: buildRisks(activeStep, catalogErrors, error),
      rawLogOutput: normalizeLogEntries(logs).join("\n"),
    },
    completion: mode === "manage" ? buildCompletion(activeStep, progress, cluster) : null,
    answers,
  };
}

export function getWizardSteps(catalog, answers = {}) {
  return flattenSetupSteps(catalog || fallbackCatalog(), answers);
}

export function getWizardPhaseBoundaries(questionSteps = [], setupSteps = []) {
  return {
    firstQuestionStep: questionSteps[0] || null,
    lastQuestionStep: questionSteps.length > 0 ? questionSteps[questionSteps.length - 1] : null,
    firstInstallStep: setupSteps[0] || null,
    lastInstallStep: setupSteps.length > 0 ? setupSteps[setupSteps.length - 1] : null,
  };
}

export function getNextInstallableSetupStep(
  catalog,
  answers = {},
  fromStepId = "",
  excludedStepIds = new Set()
) {
  const steps = getWizardSteps(catalog, answers);
  const startIndex = fromStepId
    ? Math.max(
        0,
        steps.findIndex((step) => step.id === fromStepId)
      )
    : 0;

  return (
    steps
      .slice(startIndex)
      .find(
        (step) =>
          step.status !== "done" && step.status !== "configured" && !excludedStepIds.has(step.id)
      ) || null
  );
}
