import * as k8s from "@kubernetes/client-node";

async function listArgocdApplications() {
  try {
    const kc = new k8s.KubeConfig();
    kc.loadFromCluster();
    const customObjects = kc.makeApiClient(k8s.CustomObjectsApi);
    const res = await customObjects.listClusterCustomObject({
      group: "argoproj.io",
      version: "v1alpha1",
      plural: "applications",
    });
    const apps = [];
    for (const app of res.body.items) {
      apps.push({
        name: app.metadata?.name,
        namespace: app.metadata?.namespace,
        syncStatus: app.status?.sync?.status,
        healthStatus: app.status?.health?.status,
        syncRevision: app.status?.sync?.revision?.slice(0, 12),
        conditions: app.status?.conditions,
        operationState: app.status?.operationState
          ? {
              phase: app.status.operationState.phase,
              message: app.status.operationState.message,
              startedAt: app.status.operationState.startedAt,
              finishedAt: app.status.operationState.finishedAt,
            }
          : null,
      });
    }
    return apps;
  } catch (err) {
    return { error: err.message, available: false };
  }
}

async function listArgocdWarningEvents() {
  try {
    const kc = new k8s.KubeConfig();
    kc.loadFromCluster();
    const core = kc.makeApiClient(k8s.CoreV1Api);
    const oneHourAgo = new Date(Date.now() - 60 * 60 * 1000).toISOString();
    const res = await core.listNamespacedEvent({ namespace: "argocd" });
    const warnings = [];
    for (const ev of res.body.items) {
      if (ev.type !== "Warning") continue;
      const lastSeen = ev.metadata?.creationTimestamp
        ? new Date(ev.metadata.creationTimestamp).toISOString()
        : null;
      if (lastSeen && lastSeen < oneHourAgo) continue;
      warnings.push({
        name: ev.metadata?.name,
        reason: ev.reason,
        message: ev.message,
        kind: ev.involvedObject?.kind,
        objectName: ev.involvedObject?.name,
        lastSeen: ev.lastTimestamp || ev.metadata?.creationTimestamp,
        count: ev.count,
      });
    }
    return warnings;
  } catch (err) {
    return { error: err.message, available: false };
  }
}

export { listArgocdApplications, listArgocdWarningEvents };
