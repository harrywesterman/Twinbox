import * as k8s from "@kubernetes/client-node";

async function createKubernetesClients() {
  const kc = new k8s.KubeConfig();
  kc.loadFromCluster();

  return {
    core: kc.makeApiClient(k8s.CoreV1Api),
    apps: kc.makeApiClient(k8s.AppsV1Api),
    batch: kc.makeApiClient(k8s.BatchV1Api),
    customObjects: kc.makeApiClient(k8s.CustomObjectsApi),
  };
}

async function listUnhealthyPods() {
  try {
    const { core } = await createKubernetesClients();
    const res = await core.listPodForAllNamespaces();
    const unhealthy = [];
    for (const pod of res.body.items) {
      if (pod.status?.phase === "Succeeded" || pod.status?.phase === "Failed") {
        continue;
      }
      const ready = pod.status?.conditions?.some((c) => c.type === "Ready" && c.status === "True");
      if (!ready) {
        unhealthy.push({
          name: pod.metadata?.name,
          namespace: pod.metadata?.namespace,
          phase: pod.status?.phase,
          reason: pod.status?.reason || null,
          message: pod.status?.conditions
            ?.filter((c) => c.status !== "True")
            .map((c) => `${c.type}: ${c.message || c.reason || ""}`)
            .join("; "),
        });
      }
    }
    return unhealthy;
  } catch (err) {
    return { error: err.message, available: false };
  }
}

async function listRecentWarningEvents() {
  try {
    const { core } = await createKubernetesClients();
    const oneHourAgo = new Date(Date.now() - 60 * 60 * 1000).toISOString();
    const res = await core.listEventForAllNamespaces();
    const warnings = [];
    for (const ev of res.body.items) {
      if (ev.type !== "Warning") {
        continue;
      }
      const lastSeen = ev.metadata?.creationTimestamp
        ? new Date(ev.metadata.creationTimestamp).toISOString()
        : null;
      if (lastSeen && lastSeen < oneHourAgo) {
        continue;
      }
      warnings.push({
        name: ev.metadata?.name,
        namespace: ev.metadata?.namespace,
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

async function summarizeNodes() {
  try {
    const { core } = await createKubernetesClients();
    const res = await core.listNode();
    const nodes = [];
    for (const node of res.body.items) {
      const ready = node.status?.conditions?.find((c) => c.type === "Ready");
      nodes.push({
        name: node.metadata?.name,
        ready: ready?.status === "True",
        status: ready?.status || "Unknown",
        roles: node.metadata?.labels?.["node-role.kubernetes.io/control-plane"]
          ? ["control-plane"]
          : ["worker"],
        kubeletVersion: node.status?.nodeInfo?.kubeletVersion,
        osImage: node.status?.nodeInfo?.osImage,
        capacity: node.status?.capacity,
        allocatable: node.status?.allocatable,
      });
    }
    return nodes;
  } catch (err) {
    return { error: err.message, available: false };
  }
}

async function summarizeCloudNativePgClusters() {
  try {
    const { customObjects } = await createKubernetesClients();
    const res = await customObjects.listClusterCustomObject({
      group: "postgresql.cnpg.io",
      version: "v1",
      plural: "clusters",
    });
    const clusters = [];
    for (const cluster of res.body.items) {
      clusters.push({
        name: cluster.metadata?.name,
        namespace: cluster.metadata?.namespace,
        status: cluster.status?.phase || cluster.status?.state || "Unknown",
        instances: cluster.status?.instances,
        readyInstances: cluster.status?.readyInstances,
        instancesStatus: cluster.status?.instancesStatus,
        conditions: cluster.status?.conditions,
      });
    }
    return clusters;
  } catch (err) {
    return { error: err.message, available: false };
  }
}

async function summarizeScheduledBackups() {
  try {
    const { customObjects } = await createKubernetesClients();
    const res = await customObjects.listClusterCustomObject({
      group: "postgresql.cnpg.io",
      version: "v1",
      plural: "scheduledbackups",
    });
    const backups = [];
    for (const sb of res.body.items) {
      backups.push({
        name: sb.metadata?.name,
        namespace: sb.metadata?.namespace,
        schedule: sb.spec?.schedule,
        cluster: sb.spec?.cluster?.name,
        lastBackup: sb.status?.lastBackup,
        lastSuccessfulBackup: sb.status?.lastSuccessfulBackup,
        status: sb.status?.phase || "Unknown",
      });
    }
    return backups;
  } catch (err) {
    return { error: err.message, available: false };
  }
}

async function summarizeVeleroBackups() {
  try {
    const { customObjects } = await createKubernetesClients();
    const res = await customObjects.listClusterCustomObject({
      group: "velero.io",
      version: "v1",
      plural: "backups",
    });
    const backups = [];
    for (const b of res.body.items) {
      backups.push({
        name: b.metadata?.name,
        namespace: b.metadata?.namespace,
        phase: b.status?.phase,
        startTimestamp: b.status?.startTimestamp,
        completionTimestamp: b.status?.completionTimestamp,
        expiration: b.status?.expiration,
        errors: b.status?.errors,
        warnings: b.status?.warnings,
        itemsBackedUp: b.status?.itemsBackedUp,
      });
    }
    return backups;
  } catch (err) {
    return { error: err.message, available: false };
  }
}

async function summarizeLonghornRecurringJobs() {
  try {
    const { customObjects } = await createKubernetesClients();
    const res = await customObjects.listClusterCustomObject({
      group: "longhorn.io",
      version: "v1beta2",
      plural: "recurringjobs",
    });
    const jobs = [];
    for (const j of res.body.items) {
      jobs.push({
        name: j.metadata?.name,
        namespace: j.metadata?.namespace,
        spec: j.spec,
      });
    }
    return jobs;
  } catch (err) {
    return { error: err.message, available: false };
  }
}

export {
  createKubernetesClients,
  listUnhealthyPods,
  listRecentWarningEvents,
  summarizeNodes,
  summarizeCloudNativePgClusters,
  summarizeScheduledBackups,
  summarizeVeleroBackups,
  summarizeLonghornRecurringJobs,
};
