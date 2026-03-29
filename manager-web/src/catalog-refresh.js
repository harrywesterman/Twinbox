import { getWizardSteps } from './journey.js';

const PROVISION_STEP_ID = 'provision-nodes';
const MISSING_CLUSTER_NOTICE = 'The selected cluster was not found. Twinbox discarded the old step 1 draft and restarted the wizard at step 1.';
const RECREATED_CLUSTER_NOTICE = 'Twinbox detected a new cluster session and reset the old step 1 draft.';

export function isMissingClusterError(error) {
  if (!error || typeof error !== 'object') {
    return false;
  }

  const status = Number(error.status);
  if (status !== 404) {
    return false;
  }

  const message = String(error.message || error.body?.error || error.body || '');
  return /cluster not found/i.test(message);
}

export function shouldResetRecreatedClusterDraft({
  previousCreatedAt = '',
  nextCreatedAt = '',
  hasProvisionDraft = false,
} = {}) {
  if (!hasProvisionDraft || !nextCreatedAt) {
    return false;
  }

  return !previousCreatedAt || nextCreatedAt !== previousCreatedAt;
}

function pickStepId(steps, preferredStepId) {
  if (preferredStepId && steps.some((step) => step.id === preferredStepId)) {
    return preferredStepId;
  }

  return steps[0]?.id || '';
}

function discoverClusterId(catalog) {
  for (const category of catalog?.categories || []) {
    for (const step of category.steps || []) {
      const stateClusterId = step?.state?.cluster_id;
      const outputClusterId = step?.state?.outputs?.cluster_id;
      if (typeof stateClusterId === 'string' && stateClusterId) return stateClusterId;
      if (typeof outputClusterId === 'string' && outputClusterId) return outputClusterId;
    }
  }

  return '';
}

function clearStaleClusterState({
  setClusterId,
  setClusterCreatedAt,
  setSelectedStepId,
  setCluster,
  setLogs,
  setActiveJob,
  setAnswers,
  setError,
  setNotice,
  clusterIdRef,
  selectedStepIdRef,
  clusterCreatedAtRef,
  answersRef,
  provisionDirtyFieldsRef,
  provisionSuggestionKeyRef,
  provisionSuggestionSnapshotRef,
  placementSuggestionKeyRef,
  notice = MISSING_CLUSTER_NOTICE,
  clearClusterId = true,
  clearClusterCreatedAt = true,
}) {
  const currentAnswers = answersRef?.current && typeof answersRef.current === 'object'
    ? answersRef.current
    : {};
  const hasProvisionDraft = Object.prototype.hasOwnProperty.call(currentAnswers, PROVISION_STEP_ID);

  if (clearClusterId && clusterIdRef) {
    clusterIdRef.current = '';
  }
  if (clearClusterCreatedAt && clusterCreatedAtRef) {
    clusterCreatedAtRef.current = '';
  }
  if (selectedStepIdRef) {
    selectedStepIdRef.current = '';
  }
  if (answersRef) {
    answersRef.current = hasProvisionDraft
      ? Object.fromEntries(
        Object.entries(currentAnswers).filter(([stepId]) => stepId !== PROVISION_STEP_ID),
      )
      : currentAnswers;
  }
  if (provisionDirtyFieldsRef) {
    provisionDirtyFieldsRef.current = new Set();
  }
  if (provisionSuggestionKeyRef) {
    provisionSuggestionKeyRef.current = '';
  }
  if (provisionSuggestionSnapshotRef) {
    provisionSuggestionSnapshotRef.current = {};
  }
  if (placementSuggestionKeyRef) {
    placementSuggestionKeyRef.current = '';
  }

  if (clearClusterId) {
    setClusterId?.('');
  }
  if (clearClusterCreatedAt) {
    setClusterCreatedAt?.('');
  }
  setSelectedStepId?.('');
  setCluster?.(null);
  setLogs?.([]);
  setActiveJob?.(null);
  if (setAnswers) {
    setAnswers(hasProvisionDraft ? answersRef.current : currentAnswers);
  }
  setError?.('');
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
  selectedStepIdRef,
  setHealth,
  setCatalog,
  setProxmoxResources,
  setClusterId,
  setClusterCreatedAt,
  setSelectedStepId,
  setCluster,
  setLogs,
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
  clusterIdOverride = '',
  clearError = true,
}) {
  const effectiveClusterId = clusterIdOverride || clusterIdRef.current;
  const clusterQuery = effectiveClusterId
    ? `?cluster_id=${encodeURIComponent(effectiveClusterId)}`
    : '';
  const [healthData, catalogData, resourcesData] = await Promise.allSettled([
    requestJson('/api/health'),
    requestJson(`/api/catalog${clusterQuery}`),
    requestJson('/api/proxmox/cluster-resources'),
  ]);

  if (healthData.status === 'fulfilled') {
    setHealth(healthData.value);
  }
  if (resourcesData.status === 'fulfilled') {
    setProxmoxResources(resourcesData.value);
  } else {
    setProxmoxResources(null);
  }

  if (healthData.status === 'rejected') {
    throw healthData.reason instanceof Error ? healthData.reason : new Error('Failed to refresh wizard health');
  }

  let catalogValue = null;
  if (catalogData.status === 'fulfilled') {
    catalogValue = catalogData.value;
  } else if (isMissingClusterError(catalogData.reason)) {
    clearStaleClusterState({
      setClusterId,
      setClusterCreatedAt,
      setSelectedStepId,
      setCluster,
      setLogs,
      setActiveJob,
      setAnswers,
      setError,
      setNotice,
      clusterIdRef,
      selectedStepIdRef,
      clusterCreatedAtRef,
      answersRef,
      provisionDirtyFieldsRef,
      provisionSuggestionKeyRef,
      provisionSuggestionSnapshotRef,
      placementSuggestionKeyRef,
    });

    catalogValue = await requestJson('/api/catalog');
    setCatalog(catalogValue);
  } else {
    throw catalogData.reason instanceof Error ? catalogData.reason : new Error('Failed to refresh wizard state');
  }

  if (catalogData.status === 'fulfilled') {
    setCatalog(catalogValue);
  }

  const discoveredClusterId = discoverClusterId(catalogValue) || clusterIdRef.current || '';
  if (discoveredClusterId && discoveredClusterId !== clusterIdRef.current) {
    clusterIdRef.current = discoveredClusterId;
    setClusterId(discoveredClusterId);
  }

  const nextStepId = pickStepId(getWizardSteps(catalogValue), selectedStepIdRef.current);
  if (nextStepId !== selectedStepIdRef.current) {
    selectedStepIdRef.current = nextStepId;
    setSelectedStepId(nextStepId);
  }

  const selectedStep = getWizardSteps(catalogValue).find((step) => step.id === nextStepId);
  const latestJobId = selectedStep?.latest_job?.id;
  if (latestJobId) {
    try {
      const logsData = await requestJson(`/api/jobs/${encodeURIComponent(latestJobId)}/logs`);
      setLogs(Array.isArray(logsData?.lines) ? logsData.lines : []);
    } catch {
      setLogs([]);
    }
  } else {
    setLogs([]);
  }

  if (clearError) {
    setError('');
  }

  return catalogValue;
}
