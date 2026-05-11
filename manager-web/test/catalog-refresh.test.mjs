import test from "node:test";
import assert from "node:assert/strict";

import {
  isMissingClusterError,
  isProvisionSuggestionReady,
  recoverMissingClusterState,
  recoverRecreatedClusterState,
  shouldResetRecreatedClusterDraft,
  refreshWizardSnapshot,
} from "../src/catalog-refresh.js";

function makeCatalog() {
  return {
    categories: [
      {
        id: "talos-cluster",
        title: "Talos Cluster",
        summary: "Deploy the cluster end to end.",
        status: "ready",
        steps: [
          {
            id: "provision-nodes",
            title: "Deploy Talos Cluster",
            journey_stage: "setup",
            status: "ready",
            summary: "Install Talos Linux on separate VMs.",
            explanation: "Provision the Talos cluster.",
            side_help: "Start the cluster bootstrap.",
            inputs: [],
            depends_on: [],
            state: {
              status: "not_started",
              inputs: {},
              outputs: null,
              cluster_id: null,
              error: null,
              updated_at: null,
              last_job_id: null,
            },
            latest_job: null,
          },
        ],
      },
    ],
    errors: [],
  };
}

function createHttpError(status, message) {
  const error = new Error(message);
  error.status = status;
  error.body = { error: message };
  return error;
}

test("isMissingClusterError only matches 404 cluster not found responses", () => {
  assert.equal(isMissingClusterError(createHttpError(404, "cluster not found")), true);
  assert.equal(isMissingClusterError(createHttpError(404, "catalog unavailable")), false);
  assert.equal(isMissingClusterError(createHttpError(500, "cluster not found")), false);
  assert.equal(isMissingClusterError(null), false);
});

test("shouldResetRecreatedClusterDraft detects a cluster generation mismatch", () => {
  assert.equal(
    shouldResetRecreatedClusterDraft({
      previousClusterInstanceId: "11111111-1111-1111-1111-111111111111",
      nextClusterInstanceId: "22222222-2222-2222-2222-222222222222",
      nextCreatedAt: "2026-03-30T00:00:00Z",
      hasProvisionDraft: true,
    }),
    true
  );
  assert.equal(
    shouldResetRecreatedClusterDraft({
      previousClusterInstanceId: "11111111-1111-1111-1111-111111111111",
      nextClusterInstanceId: "11111111-1111-1111-1111-111111111111",
      nextCreatedAt: "2026-03-30T00:00:00Z",
      hasProvisionDraft: true,
    }),
    false
  );
  assert.equal(
    shouldResetRecreatedClusterDraft({
      previousCreatedAt: "",
      nextCreatedAt: "2026-03-30T00:00:00Z",
      hasProvisionDraft: true,
    }),
    true
  );
  assert.equal(
    shouldResetRecreatedClusterDraft({
      previousCreatedAt: "2026-03-20T10:00:00Z",
      nextCreatedAt: "2026-03-30T00:00:00Z",
      hasProvisionDraft: true,
    }),
    true
  );
  assert.equal(
    shouldResetRecreatedClusterDraft({
      previousCreatedAt: "2026-03-30T00:00:00Z",
      nextCreatedAt: "2026-03-30T00:00:00Z",
      hasProvisionDraft: true,
    }),
    false
  );
  assert.equal(
    shouldResetRecreatedClusterDraft({
      previousCreatedAt: "2026-03-20T10:00:00Z",
      nextCreatedAt: "2026-03-30T00:00:00Z",
      hasProvisionDraft: false,
    }),
    false
  );
});

test("isProvisionSuggestionReady only unlocks step 1 after the current suggestions are loaded", () => {
  assert.equal(
    isProvisionSuggestionReady({
      activeStepId: "provision-nodes",
      suggestionKey: "192.168.2.52:5",
      currentSuggestionKey: "",
      suggestionSnapshot: {},
    }),
    false
  );

  assert.equal(
    isProvisionSuggestionReady({
      activeStepId: "provision-nodes",
      suggestionKey: "192.168.2.52:5",
      currentSuggestionKey: "192.168.2.52:5",
      suggestionSnapshot: { name: "twinbox-tst" },
    }),
    true
  );

  assert.equal(
    isProvisionSuggestionReady({
      activeStepId: "provision-nodes",
      suggestionKey: "192.168.2.52:5",
      currentSuggestionKey: "192.168.2.52:3",
      suggestionSnapshot: { name: "twinbox-tst" },
    }),
    false
  );

  assert.equal(
    isProvisionSuggestionReady({
      activeStepId: "install-argocd",
    }),
    true
  );
});

test("recoverMissingClusterState keeps the current browser draft intact while clearing runtime state", () => {
  const state = {
    clusterId: "tst",
    clusterCreatedAt: "2026-03-20T10:00:00Z",
    clusterInstanceId: "11111111-1111-1111-1111-111111111111",
    selectedStepId: "provision-nodes",
    cluster: { id: "tst" },
    logs: ["old log"],
    activeJob: { id: "job-1" },
    answers: {
      "provision-nodes": {
        name: "twinbox-tst",
        start_vmid: 122,
        vip_ip: "192.168.2.50",
      },
    },
    notice: "",
    error: "stale",
  };
  const clusterIdRef = { current: "tst" };
  const clusterCreatedAtRef = { current: "2026-03-20T10:00:00Z" };
  const clusterInstanceIdRef = { current: "11111111-1111-1111-1111-111111111111" };
  const selectedStepIdRef = { current: "provision-nodes" };
  const answersRef = {
    current: state.answers,
  };
  const provisionDirtyFieldsRef = {
    current: new Set(["start_vmid", "vip_ip"]),
  };
  const provisionSuggestionKeyRef = {
    current: "192.168.2.52:5",
  };
  const provisionSuggestionSnapshotRef = {
    current: {
      start_vmid: 122,
      vip_ip: "192.168.2.50",
    },
  };
  const placementSuggestionKeyRef = {
    current: "tst:provision-nodes",
  };
  let clearInstallLogsCalls = 0;

  recoverMissingClusterState({
    setClusterId: (value) => {
      state.clusterId = value;
    },
    setClusterCreatedAt: (value) => {
      state.clusterCreatedAt = value;
    },
    setClusterInstanceId: (value) => {
      state.clusterInstanceId = value;
    },
    setSelectedStepId: (value) => {
      state.selectedStepId = value;
    },
    setCluster: (value) => {
      state.cluster = value;
    },
    setLogs: (value) => {
      state.logs = value;
    },
    setActiveJob: (value) => {
      state.activeJob = value;
    },
    setAnswers: (value) => {
      state.answers = value;
    },
    setNotice: (value) => {
      state.notice = value;
    },
    setError: (value) => {
      state.error = value;
    },
    clearInstallLogs: () => {
      clearInstallLogsCalls += 1;
    },
    clusterIdRef,
    clusterCreatedAtRef,
    clusterInstanceIdRef,
    selectedStepIdRef,
    answersRef,
    provisionDirtyFieldsRef,
    provisionSuggestionKeyRef,
    provisionSuggestionSnapshotRef,
    placementSuggestionKeyRef,
  });

  assert.equal(clusterIdRef.current, "tst");
  assert.equal(clusterCreatedAtRef.current, "2026-03-20T10:00:00Z");
  assert.equal(clusterInstanceIdRef.current, "11111111-1111-1111-1111-111111111111");
  assert.equal(selectedStepIdRef.current, "provision-nodes");
  assert.equal(state.clusterId, "tst");
  assert.equal(state.clusterCreatedAt, "2026-03-20T10:00:00Z");
  assert.equal(state.clusterInstanceId, "11111111-1111-1111-1111-111111111111");
  assert.equal(state.selectedStepId, "provision-nodes");
  assert.equal(state.cluster, null);
  assert.deepEqual(state.logs, []);
  assert.equal(state.activeJob, null);
  assert.deepEqual(state.answers, {
    "provision-nodes": {
      name: "twinbox-tst",
      start_vmid: 122,
      vip_ip: "192.168.2.50",
    },
  });
  assert.deepEqual(answersRef.current, state.answers);
  assert.deepEqual([...provisionDirtyFieldsRef.current], []);
  assert.equal(provisionSuggestionKeyRef.current, "");
  assert.deepEqual(provisionSuggestionSnapshotRef.current, {});
  assert.equal(placementSuggestionKeyRef.current, "");
  assert.equal(clearInstallLogsCalls, 1);
  assert.equal(
    state.notice,
    "Twinbox is waiting for the cluster catalog. Your saved answers and current step are still preserved."
  );
  assert.equal(state.error, "");
});

test("recoverRecreatedClusterState keeps the current browser draft intact while clearing runtime state", () => {
  const state = {
    clusterId: "tst",
    clusterCreatedAt: "2026-03-20T10:00:00Z",
    clusterInstanceId: "11111111-1111-1111-1111-111111111111",
    selectedStepId: "install-secret-sync",
    cluster: { id: "tst" },
    logs: ["old log"],
    activeJob: { id: "job-1" },
    answers: {
      "provision-nodes": {
        name: "twinbox-tst",
        start_vmid: 122,
        vip_ip: "192.168.2.50",
      },
      "install-secret-sync": {
        openbao_hostname: "openbao.internal",
      },
    },
    notice: "",
    error: "stale",
  };
  const clusterIdRef = { current: "tst" };
  const clusterCreatedAtRef = { current: "2026-03-20T10:00:00Z" };
  const clusterInstanceIdRef = { current: "11111111-1111-1111-1111-111111111111" };
  const selectedStepIdRef = { current: "install-secret-sync" };
  const answersRef = {
    current: state.answers,
  };
  const provisionDirtyFieldsRef = {
    current: new Set(["start_vmid", "vip_ip"]),
  };
  const provisionSuggestionKeyRef = {
    current: "192.168.2.52:5",
  };
  const provisionSuggestionSnapshotRef = {
    current: {
      start_vmid: 122,
      vip_ip: "192.168.2.50",
    },
  };
  const placementSuggestionKeyRef = {
    current: "tst:provision-nodes",
  };
  let clearInstallLogsCalls = 0;

  recoverRecreatedClusterState({
    setClusterCreatedAt: (value) => {
      state.clusterCreatedAt = value;
    },
    setClusterInstanceId: (value) => {
      state.clusterInstanceId = value;
    },
    setSelectedStepId: (value) => {
      state.selectedStepId = value;
    },
    setCluster: (value) => {
      state.cluster = value;
    },
    setLogs: (value) => {
      state.logs = value;
    },
    setActiveJob: (value) => {
      state.activeJob = value;
    },
    setAnswers: (value) => {
      state.answers = value;
    },
    setNotice: (value) => {
      state.notice = value;
    },
    setError: (value) => {
      state.error = value;
    },
    clearInstallLogs: () => {
      clearInstallLogsCalls += 1;
    },
    clusterIdRef,
    clusterCreatedAtRef,
    clusterInstanceIdRef,
    selectedStepIdRef,
    answersRef,
    provisionDirtyFieldsRef,
    provisionSuggestionKeyRef,
    provisionSuggestionSnapshotRef,
    placementSuggestionKeyRef,
  });

  assert.equal(clusterIdRef.current, "tst");
  assert.equal(clusterCreatedAtRef.current, "2026-03-20T10:00:00Z");
  assert.equal(clusterInstanceIdRef.current, "11111111-1111-1111-1111-111111111111");
  assert.equal(selectedStepIdRef.current, "install-secret-sync");
  assert.equal(state.clusterId, "tst");
  assert.equal(state.clusterCreatedAt, "2026-03-20T10:00:00Z");
  assert.equal(state.clusterInstanceId, "11111111-1111-1111-1111-111111111111");
  assert.equal(state.selectedStepId, "install-secret-sync");
  assert.equal(state.cluster, null);
  assert.deepEqual(state.logs, []);
  assert.equal(state.activeJob, null);
  assert.deepEqual(state.answers, {
    "provision-nodes": {
      name: "twinbox-tst",
      start_vmid: 122,
      vip_ip: "192.168.2.50",
    },
    "install-secret-sync": {
      openbao_hostname: "openbao.internal",
    },
  });
  assert.deepEqual(answersRef.current, state.answers);
  assert.deepEqual([...provisionDirtyFieldsRef.current], []);
  assert.equal(provisionSuggestionKeyRef.current, "");
  assert.deepEqual(provisionSuggestionSnapshotRef.current, {});
  assert.equal(placementSuggestionKeyRef.current, "");
  assert.equal(clearInstallLogsCalls, 1);
  assert.equal(
    state.notice,
    "Twinbox detected a new cluster session and restarted from the first question while keeping your saved answers."
  );
  assert.equal(state.error, "");
});

test("refreshWizardSnapshot preserves the draft on a temporary catalog 404 and retries without cluster filter", async () => {
  const calls = [];
  const state = {
    health: null,
    catalog: null,
    proxmoxResources: null,
    clusterId: "tst",
    clusterCreatedAt: "2026-03-20T10:00:00Z",
    clusterInstanceId: "11111111-1111-1111-1111-111111111111",
    selectedStepId: "install-secret-sync",
    cluster: { id: "tst" },
    logs: ["old log"],
    activeJob: { id: "job-1" },
    answers: {
      "provision-nodes": {
        name: "twinbox-tst",
        start_vmid: 122,
      },
      "install-secret-sync": {
        openbao_hostname: "openbao.internal",
      },
    },
    notice: "",
    error: "stale",
  };

  const requestJson = async (url) => {
    calls.push(url);

    if (url === "/api/health") {
      return { ok: true, time: "2026-03-29T19:13:11.858Z" };
    }

    if (url === "/api/proxmox/cluster-resources") {
      return {
        nodes: [],
        summary: {
          nodeCount: 0,
          totalMemoryMb: 0,
          usedMemoryMb: 0,
          freeMemoryMb: 0,
          totalDiskGb: 0,
          usedDiskGb: 0,
          freeDiskGb: 0,
          totalCpuCores: 0,
          usedCpuCores: 0,
          freeCpuCores: 0,
        },
      };
    }

    if (url === "/api/catalog?cluster_id=tst") {
      throw createHttpError(404, "cluster not found");
    }

    if (url === "/api/catalog") {
      return makeCatalog();
    }

    throw new Error(`unexpected request: ${url}`);
  };

  const clusterIdRef = { current: "tst" };
  const clusterCreatedAtRef = { current: "2026-03-20T10:00:00Z" };
  const clusterInstanceIdRef = { current: "11111111-1111-1111-1111-111111111111" };
  const selectedStepIdRef = { current: "install-secret-sync" };
  const answersRef = { current: state.answers };
  const provisionDirtyFieldsRef = { current: new Set(["start_vmid"]) };
  const provisionSuggestionKeyRef = { current: "192.168.2.52:5" };
  const provisionSuggestionSnapshotRef = { current: { start_vmid: 122 } };
  const placementSuggestionKeyRef = { current: "tst:provision-nodes" };

  await refreshWizardSnapshot({
    requestJson,
    clusterIdRef,
    clusterInstanceIdRef,
    selectedStepIdRef,
    clusterCreatedAtRef,
    answersRef,
    provisionDirtyFieldsRef,
    provisionSuggestionKeyRef,
    provisionSuggestionSnapshotRef,
    placementSuggestionKeyRef,
    setHealth: (value) => {
      state.health = value;
    },
    setCatalog: (value) => {
      state.catalog = value;
    },
    setProxmoxResources: (value) => {
      state.proxmoxResources = value;
    },
    setClusterId: (value) => {
      state.clusterId = value;
    },
    setClusterCreatedAt: (value) => {
      state.clusterCreatedAt = value;
    },
    setClusterInstanceId: (value) => {
      state.clusterInstanceId = value;
    },
    setSelectedStepId: (value) => {
      state.selectedStepId = value;
    },
    setCluster: (value) => {
      state.cluster = value;
    },
    setLogs: (value) => {
      state.logs = value;
    },
    setActiveJob: (value) => {
      state.activeJob = value;
    },
    setAnswers: (value) => {
      state.answers = value;
    },
    setNotice: (value) => {
      state.notice = value;
    },
    setError: (value) => {
      state.error = value;
    },
  });

  assert.deepEqual(calls, [
    "/api/health",
    "/api/catalog?cluster_id=tst",
    "/api/proxmox/cluster-resources",
    "/api/catalog",
  ]);
  assert.equal(clusterIdRef.current, "tst");
  assert.equal(clusterCreatedAtRef.current, "2026-03-20T10:00:00Z");
  assert.equal(clusterInstanceIdRef.current, "11111111-1111-1111-1111-111111111111");
  assert.equal(selectedStepIdRef.current, "install-secret-sync");
  assert.equal(state.clusterId, "tst");
  assert.equal(state.clusterCreatedAt, "2026-03-20T10:00:00Z");
  assert.equal(state.clusterInstanceId, "11111111-1111-1111-1111-111111111111");
  assert.equal(state.selectedStepId, "install-secret-sync");
  assert.equal(state.cluster, null);
  assert.deepEqual(state.logs, []);
  assert.equal(state.activeJob, null);
  assert.deepEqual(state.answers, {
    "provision-nodes": {
      name: "twinbox-tst",
      start_vmid: 122,
    },
    "install-secret-sync": {
      openbao_hostname: "openbao.internal",
    },
  });
  assert.deepEqual(answersRef.current, state.answers);
  assert.deepEqual([...provisionDirtyFieldsRef.current], []);
  assert.equal(provisionSuggestionKeyRef.current, "");
  assert.deepEqual(provisionSuggestionSnapshotRef.current, {});
  assert.equal(placementSuggestionKeyRef.current, "");
  assert.equal(
    state.notice,
    "Twinbox is waiting for the cluster catalog. Your saved answers and current step are still preserved."
  );
  assert.equal(state.error, "");
  assert.equal(state.catalog.categories[0].steps[0].id, "provision-nodes");
  assert.equal(state.health.ok, true);
  assert.equal(state.proxmoxResources.summary.nodeCount, 0);
});

test("refreshWizardSnapshot keeps the previous logs visible when a job has no fresh log lines yet", async () => {
  const calls = [];
  const installLogUpdates = [];
  const state = {
    health: null,
    catalog: null,
    proxmoxResources: null,
    clusterId: "tst",
    clusterCreatedAt: "2026-03-20T10:00:00Z",
    clusterInstanceId: "11111111-1111-1111-1111-111111111111",
    selectedStepId: "install-secret-sync",
    cluster: { id: "tst" },
    logs: ["[2026-03-29T19:13:11.858Z] old log line"],
    activeJob: { id: "job-1" },
    answers: {
      "install-secret-sync": {
        openbao_hostname: "openbao.internal",
      },
    },
    notice: "",
    error: "stale",
  };
  const catalog = {
    categories: [
      {
        id: "talos-cluster",
        title: "Talos Cluster",
        summary: "Deploy the cluster end to end.",
        status: "ready",
        steps: [
          {
            id: "install-secret-sync",
            title: "Install Secret Sync",
            journey_stage: "install",
            status: "running",
            summary: "Install External Secrets Operator and OpenBao.",
            explanation: "Install the secret layer.",
            side_help: "Keep the current output visible until new lines arrive.",
            inputs: [],
            depends_on: [],
            state: {
              status: "running",
              inputs: {},
              outputs: null,
              cluster_id: "tst",
              error: null,
              updated_at: null,
              last_job_id: "job-1",
            },
            latest_job: {
              id: "job-1",
              status: "running",
              cluster_id: "tst",
              cluster_instance_id: "11111111-1111-1111-1111-111111111111",
            },
          },
        ],
      },
    ],
    errors: [],
  };

  const requestJson = async (url) => {
    calls.push(url);

    if (url === "/api/health") {
      return { ok: true, time: "2026-03-29T19:13:11.858Z" };
    }

    if (url === "/api/proxmox/cluster-resources") {
      return {
        nodes: [],
        summary: {
          nodeCount: 0,
          totalMemoryMb: 0,
          usedMemoryMb: 0,
          freeMemoryMb: 0,
          totalDiskGb: 0,
          usedDiskGb: 0,
          freeDiskGb: 0,
          totalCpuCores: 0,
          usedCpuCores: 0,
          freeCpuCores: 0,
        },
      };
    }

    if (url === "/api/catalog?cluster_id=tst") {
      return catalog;
    }

    if (url === "/api/jobs/job-1/logs") {
      return { lines: [] };
    }

    throw new Error(`unexpected request: ${url}`);
  };

  const clusterIdRef = { current: "tst" };
  const clusterCreatedAtRef = { current: "2026-03-20T10:00:00Z" };
  const clusterInstanceIdRef = { current: "11111111-1111-1111-1111-111111111111" };
  const selectedStepIdRef = { current: "install-secret-sync" };
  const answersRef = { current: state.answers };
  const provisionDirtyFieldsRef = { current: new Set(["start_vmid"]) };
  const provisionSuggestionKeyRef = { current: "192.168.2.52:5" };
  const provisionSuggestionSnapshotRef = { current: { start_vmid: 122 } };
  const placementSuggestionKeyRef = { current: "tst:provision-nodes" };

  await refreshWizardSnapshot({
    requestJson,
    clusterIdRef,
    clusterInstanceIdRef,
    selectedStepIdRef,
    clusterCreatedAtRef,
    answersRef,
    provisionDirtyFieldsRef,
    provisionSuggestionKeyRef,
    provisionSuggestionSnapshotRef,
    placementSuggestionKeyRef,
    setHealth: (value) => {
      state.health = value;
    },
    setCatalog: (value) => {
      state.catalog = value;
    },
    setProxmoxResources: (value) => {
      state.proxmoxResources = value;
    },
    setClusterId: (value) => {
      state.clusterId = value;
    },
    setClusterCreatedAt: (value) => {
      state.clusterCreatedAt = value;
    },
    setClusterInstanceId: (value) => {
      state.clusterInstanceId = value;
    },
    setSelectedStepId: (value) => {
      state.selectedStepId = value;
    },
    setCluster: (value) => {
      state.cluster = value;
    },
    setLogs: (value) => {
      state.logs = value;
    },
    setInstallStepLogs: (stepId, lines) => {
      installLogUpdates.push({ stepId, lines });
    },
    setActiveJob: (value) => {
      state.activeJob = value;
    },
    setAnswers: (value) => {
      state.answers = value;
    },
    setNotice: (value) => {
      state.notice = value;
    },
    setError: (value) => {
      state.error = value;
    },
  });

  assert.deepEqual(calls, [
    "/api/health",
    "/api/catalog?cluster_id=tst",
    "/api/proxmox/cluster-resources",
    "/api/jobs/job-1/logs",
  ]);
  assert.deepEqual(state.logs, ["[2026-03-29T19:13:11.858Z] old log line"]);
  assert.deepEqual(installLogUpdates, []);
});

test("refreshWizardSnapshot records fresh logs for the currently selected step", async () => {
  const installLogUpdates = [];
  const state = {
    health: null,
    catalog: null,
    proxmoxResources: null,
    clusterId: "tst",
    clusterCreatedAt: "2026-03-20T10:00:00Z",
    clusterInstanceId: "11111111-1111-1111-1111-111111111111",
    selectedStepId: "install-secret-sync",
    cluster: { id: "tst" },
    logs: [],
    activeJob: { id: "job-1" },
    answers: {
      "install-secret-sync": {
        openbao_hostname: "openbao.internal",
      },
    },
    notice: "",
    error: "stale",
  };
  const catalog = {
    categories: [
      {
        id: "talos-cluster",
        title: "Talos Cluster",
        summary: "Deploy the cluster end to end.",
        status: "ready",
        steps: [
          {
            id: "install-secret-sync",
            title: "Install Secret Sync",
            journey_stage: "install",
            status: "running",
            summary: "Install External Secrets Operator and OpenBao.",
            explanation: "Install the secret layer.",
            side_help: "Keep the current output visible until new lines arrive.",
            inputs: [],
            depends_on: [],
            state: {
              status: "running",
              inputs: {},
              outputs: null,
              cluster_id: "tst",
              error: null,
              updated_at: null,
              last_job_id: "job-1",
            },
            latest_job: {
              id: "job-1",
              status: "running",
              cluster_id: "tst",
              cluster_instance_id: "11111111-1111-1111-1111-111111111111",
            },
          },
        ],
      },
    ],
    errors: [],
  };

  const requestJson = async (url) => {
    if (url === "/api/health") {
      return { ok: true, time: "2026-03-29T19:13:11.858Z" };
    }

    if (url === "/api/proxmox/cluster-resources") {
      return {
        nodes: [],
        summary: {
          nodeCount: 0,
          totalMemoryMb: 0,
          usedMemoryMb: 0,
          freeMemoryMb: 0,
          totalDiskGb: 0,
          usedDiskGb: 0,
          freeDiskGb: 0,
          totalCpuCores: 0,
          usedCpuCores: 0,
          freeCpuCores: 0,
        },
      };
    }

    if (url === "/api/catalog?cluster_id=tst") {
      return catalog;
    }

    if (url === "/api/jobs/job-1/logs") {
      return { lines: [{ line: "[2026-03-29T19:13:11.858Z] fresh log line" }] };
    }

    throw new Error(`unexpected request: ${url}`);
  };

  const clusterIdRef = { current: "tst" };
  const clusterCreatedAtRef = { current: "2026-03-20T10:00:00Z" };
  const clusterInstanceIdRef = { current: "11111111-1111-1111-1111-111111111111" };
  const selectedStepIdRef = { current: "install-secret-sync" };
  const answersRef = { current: state.answers };
  const provisionDirtyFieldsRef = { current: new Set(["start_vmid"]) };
  const provisionSuggestionKeyRef = { current: "192.168.2.52:5" };
  const provisionSuggestionSnapshotRef = { current: { start_vmid: 122 } };
  const placementSuggestionKeyRef = { current: "tst:provision-nodes" };

  await refreshWizardSnapshot({
    requestJson,
    clusterIdRef,
    clusterInstanceIdRef,
    selectedStepIdRef,
    clusterCreatedAtRef,
    answersRef,
    provisionDirtyFieldsRef,
    provisionSuggestionKeyRef,
    provisionSuggestionSnapshotRef,
    placementSuggestionKeyRef,
    setHealth: (value) => {
      state.health = value;
    },
    setCatalog: (value) => {
      state.catalog = value;
    },
    setProxmoxResources: (value) => {
      state.proxmoxResources = value;
    },
    setClusterId: (value) => {
      state.clusterId = value;
    },
    setClusterCreatedAt: (value) => {
      state.clusterCreatedAt = value;
    },
    setClusterInstanceId: (value) => {
      state.clusterInstanceId = value;
    },
    setSelectedStepId: (value) => {
      state.selectedStepId = value;
    },
    setCluster: (value) => {
      state.cluster = value;
    },
    setLogs: (value) => {
      state.logs = value;
    },
    setInstallStepLogs: (stepId, lines) => {
      installLogUpdates.push({ stepId, lines });
    },
    setActiveJob: (value) => {
      state.activeJob = value;
    },
    setAnswers: (value) => {
      state.answers = value;
    },
    setNotice: (value) => {
      state.notice = value;
    },
    setError: (value) => {
      state.error = value;
    },
  });

  assert.deepEqual(state.logs, ["[2026-03-29T19:13:11.858Z] fresh log line"]);
  assert.deepEqual(installLogUpdates, [
    {
      stepId: "install-secret-sync",
      lines: ["[2026-03-29T19:13:11.858Z] fresh log line"],
    },
  ]);
});
