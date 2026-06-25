const DEFAULT_MANAGER_API_BASE_URL = "http://webwizard.longhorn-system.svc.cluster.local:8080";

function getBaseUrl() {
  return process.env.MANAGER_API_BASE_URL || DEFAULT_MANAGER_API_BASE_URL;
}

async function getManagerHealth() {
  const baseUrl = getBaseUrl();
  const response = await fetch(`${baseUrl}/api/health`);
  if (!response.ok) {
    throw new Error(`manager health check failed: ${response.status} ${response.statusText}`);
  }
  return response.json();
}

async function getActiveClusterSummary() {
  const baseUrl = getBaseUrl();
  const response = await fetch(`${baseUrl}/api/clusters/active`);
  if (!response.ok) {
    return { error: `failed to get active cluster: ${response.status}` };
  }
  return response.json();
}

async function getProxmoxClusterResources() {
  const baseUrl = getBaseUrl();
  const response = await fetch(`${baseUrl}/api/proxmox/cluster-resources`);
  if (!response.ok) {
    return { error: `failed to get proxmox resources: ${response.status}` };
  }
  return response.json();
}

function queueApprovedManagerAction(_action) {
  throw new Error("NOT_IMPLEMENTED");
}

export {
  getManagerHealth,
  getActiveClusterSummary,
  getProxmoxClusterResources,
  queueApprovedManagerAction,
};
