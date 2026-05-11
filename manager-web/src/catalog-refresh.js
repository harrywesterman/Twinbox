import { getWizardSteps } from "./journey.js";
import { normalizeLogEntries } from "./install-logs.js";

const PROVISION_STEP_ID = "provision-nodes";
const MISSING_CLUSTER_NOTICE =
  "Twinbox is waiting for the cluster catalog. Your saved answers and current step are still preserved.";
const RECREATED_CLUSTER_NOTICE =
  "Twinbox detected a new cluster session and restarted from the first question while keeping your saved answers.";

export function isMissingClusterError(error) {
  if (!error || typeof error !== "object") {
    return false;
  }

  const status = Number(error.status);
  if (status !== 404) {
    return false;
  }

  const message = String(error.message || error.body?.error || error.body || "");
  return /cluster not found/i.test(message);
}

export function shouldResetRecreatedClusterDraft({
  previousClusterInstanceId = "",
  nextClusterInstanceId = "",
  previousCreatedAt = "",
  nextCreatedAt = "",
  hasProvisionDraft = false,
} = {}) {
  if (!hasProvisionDraft || !nextCreatedAt) {
    return false;
  }

  if (nextClusterInstanceId) {
    return nextClusterInstanceId !== previousClusterInstanceId;
  }

  return !previousCreatedAt || nextCreatedAt !== previousCreatedAt;
}

export function isProvisionSuggestionReady({
  activeStepId = "",
  suggestionKey = "",
  currentSuggestionKey = "",
  suggestionSnapshot = {},
} = {}) {
  if (activeStepId !== PROVISION_STEP_ID) {
    return true;
  }

  return (
    currentSuggestionKey === suggestionKey &&
    suggestionSnapshot &&
    Object.keys(suggestionSnapshot).length > 0
  );
}

function discoverClusterId(catalog) {
  for (const category of catalog?.categories || []) {
    for (const step of category.steps || []) {
      const stateClusterId = step?.state?.cluster_id;
      const outputClusterId = step?.state?.outputs?.cluster_id;
      if (typeof stateClusterId === "string" && stateClusterId) return stateClusterId;
      if (typeof outputClusterId === "string" && outputClusterId) return outputClusterId;
    }
  }

  return "";
}

function discoverClusterInstanceId(catalog) {
  for (const category of catalog?.categories || []) {
    for (const step of category.steps || []) {
      const stateClusterInstanceId = step?.state?.cluster_instance_id;
      const outputClusterInstanceId = step?.state?.outputs?.cluster_instance_id;
      if (typeof stateClusterInstanceId === "string" && stateClusterInstanceId)
        return stateClusterInstanceId;
      if (typeof outputClusterInstanceId === "string" && outputClusterInstanceId)
        return outputClusterInstanceId;
    }
  }

  return "";
}

function clearStaleClusterState({
  setCluster,
  setLogs,
  clearInstallLogs,
  setActiveJob,
  setError,
  setNotice,
  provisionDirtyFieldsRef,
  provisionSuggestionKeyRef,
  provisionSuggestionSnapshotRef,
  placementSuggestionKeyRef,
  setProvisionSuggestionsReady,
  notice = MISSING_CLUSTER_NOTICE,
}) {
  if (provisionDirtyFieldsRef) {
    provisionDirtyFieldsRef.current = new Set();
  }
  if (provisionSuggestionKeyRef) {
    provisionSuggestionKeyRef.current = "";
  }
  if (provisionSuggestionSnapshotRef) {
    provisionSuggestionSnapshotRef.current = {};
  }
  if (placementSuggestionKeyRef) {
    placementSuggestionKeyRef.current = "";
  }
  setProvisionSuggestionsReady?.(false);

  setCluster?.(null);
  setLogs?.([]);
  clearInstallLogs?.();
  setActiveJob?.(null);
  setError?.("");
  setNotice?.(notice);
}

export function recoverMissingClusterState(options = {}) {
  clearStaleClusterState(options);
}

export function recoverRecreatedClusterState(options = {}) {
  clearStaleClusterState({
    ...options,
    notice: RECREATED_CLUSTER_NOTICE,
    clearClusterId: false,
    clearClusterCreatedAt: false,
  });
}

export async function refreshWizardSnapshot({
  requestJson,
  clusterIdRef,
  clusterInstanceIdRef,
  selectedStepIdRef,
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
  answersRef,
  provisionDirtyFieldsRef,
  provisionSuggestionKeyRef,
  provisionSuggestionSnapshotRef,
  placementSuggestionKeyRef,
  clusterCreatedAtRef,
  clusterIdOverride = "",
  clearError = true,
  allowAutoSelectStep = true,
}) {
  const effectiveClusterId = clusterIdOverride || clusterIdRef.current;
  const clusterQuery = effectiveClusterId
    ? `?cluster_id=${encodeURIComponent(effectiveClusterId)}`
    : "";
  const [healthData, catalogData, resourcesData] = await Promise.allSettled([
    requestJson("/api/health"),
    requestJson(`/api/catalog${clusterQuery}`),
    requestJson("/api/proxmox/cluster-resources"),
  ]);

  if (healthData.status === "fulfilled") {
    setHealth(healthData.value);
  }
  if (resourcesData.status === "fulfilled") {
    setProxmoxResources(resourcesData.value);
  } else {
    setProxmoxResources(null);
  }

  if (healthData.status === "rejected") {
    throw healthData.reason instanceof Error
      ? healthData.reason
      : new Error("Failed to refresh wizard health");
  }

  let catalogValue = null;
  if (catalogData.status === "fulfilled") {
    catalogValue = catalogData.value;
  } else if (isMissingClusterError(catalogData.reason)) {
    clearStaleClusterState({
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
      clusterInstanceIdRef,
      selectedStepIdRef,
      clusterCreatedAtRef,
      answersRef,
      provisionDirtyFieldsRef,
      provisionSuggestionKeyRef,
      provisionSuggestionSnapshotRef,
      placementSuggestionKeyRef,
    });

    catalogValue = await requestJson("/api/catalog");
    setCatalog(catalogValue);
  } else {
    throw catalogData.reason instanceof Error
      ? catalogData.reason
      : new Error("Failed to refresh wizard state");
  }

  if (catalogData.status === "fulfilled") {
    setCatalog(catalogValue);
  }

  const discoveredClusterId = discoverClusterId(catalogValue) || clusterIdRef.current || "";
  if (discoveredClusterId && discoveredClusterId !== clusterIdRef.current) {
    clusterIdRef.current = discoveredClusterId;
    setClusterId(discoveredClusterId);
  }

  const discoveredClusterInstanceId =
    discoverClusterInstanceId(catalogValue) || clusterInstanceIdRef.current || "";
  if (discoveredClusterInstanceId && discoveredClusterInstanceId !== clusterInstanceIdRef.current) {
    clusterInstanceIdRef.current = discoveredClusterInstanceId;
    setClusterInstanceId?.(discoveredClusterInstanceId);
  }

  const steps = getWizardSteps(catalogValue, answersRef.current);
  const currentSelectedStepId = selectedStepIdRef.current || "";
  const nextStepId =
    !currentSelectedStepId && allowAutoSelectStep ? steps[0]?.id || "" : currentSelectedStepId;
  const effectiveSelectedStepId = currentSelectedStepId || nextStepId;
  if (allowAutoSelectStep && !currentSelectedStepId && nextStepId) {
    selectedStepIdRef.current = nextStepId;
    setSelectedStepId(nextStepId);
  }

  const selectedStep = steps.find((step) => step.id === effectiveSelectedStepId);
  const activeJobStep = steps.find(
    (step) =>
      step.status === "running" ||
      (step.latest_job &&
        ["pending", "running", "cancel_requested"].includes(step.latest_job.status))
  );
  const activeJob = activeJobStep?.latest_job || null;
  const activeJobId = activeJob?.id || activeJobStep?.state?.last_job_id || null;
  const latestJobId = selectedStep?.latest_job?.id;
  if (activeJobId) {
    setActiveJob?.({
      id: activeJobId,
      stepId: activeJobStep.id,
      clusterId:
        activeJob?.cluster_id ||
        activeJobStep?.state?.cluster_id ||
        discoveredClusterId ||
        clusterIdRef.current ||
        "",
      clusterInstanceId:
        activeJob?.cluster_instance_id ||
        activeJobStep?.state?.cluster_instance_id ||
        discoveredClusterInstanceId ||
        clusterInstanceIdRef.current ||
        "",
      status: activeJob?.status || activeJobStep?.status || "running",
    });
  } else if (
    selectedStep?.latest_job?.status &&
    ["canceled", "failed", "succeeded"].includes(selectedStep.latest_job.status)
  ) {
    setActiveJob?.(null);
  }
  if (latestJobId) {
    try {
      const logsData = await requestJson(`/api/jobs/${encodeURIComponent(latestJobId)}/logs`);
      const lines = normalizeLogEntries(logsData?.lines);
      if (lines.length > 0) {
        setLogs(lines);
        setInstallStepLogs?.(selectedStep?.id || currentSelectedStepId, lines);
      }
    } catch {
      // Keep the cached output for this step until fresh output is available.
    }
  }

  if (clearError) {
    setError("");
  }

  return catalogValue;
}
