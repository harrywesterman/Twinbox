import { getWizardSteps } from './journey.js';

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

function clearMissingClusterState({
  setClusterId,
  setSelectedStepId,
  setCluster,
  setLogs,
  setActiveJob,
  setError,
  setNotice,
  clusterIdRef,
  selectedStepIdRef,
  notice = 'The selected cluster was not found. Twinbox restarted the wizard at step 1.',
}) {
  if (clusterIdRef) {
    clusterIdRef.current = '';
  }
  if (selectedStepIdRef) {
    selectedStepIdRef.current = '';
  }

  setClusterId?.('');
  setSelectedStepId?.('');
  setCluster?.(null);
  setLogs?.([]);
  setActiveJob?.(null);
  setError?.('');
  setNotice?.(notice);
}

export function recoverMissingClusterState(options = {}) {
  clearMissingClusterState(options);
}

export async function refreshWizardSnapshot({
  requestJson,
  clusterIdRef,
  selectedStepIdRef,
  setHealth,
  setCatalog,
  setProxmoxResources,
  setClusterId,
  setSelectedStepId,
  setCluster,
  setLogs,
  setActiveJob,
  setNotice,
  setError,
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
    clearMissingClusterState({
      setClusterId,
      setSelectedStepId,
      setCluster,
      setLogs,
      setActiveJob,
      setError,
      setNotice,
      clusterIdRef,
      selectedStepIdRef,
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
