import test from "node:test";
import assert from "node:assert/strict";

import { buildClusterPressureSummary } from "../src/lib/cluster-pressure.js";

function node(name, cpu = "2000m", memory = "8Gi") {
  return {
    metadata: { name },
    status: {
      allocatable: {
        cpu,
        memory,
      },
    },
  };
}

function pod(name, nodeName, requests = {}) {
  return {
    metadata: { name, namespace: "default" },
    spec: {
      nodeName,
      containers: [
        {
          name: "app",
          resources: {
            requests,
          },
        },
      ],
    },
    status: {
      phase: "Running",
      conditions: [{ type: "Ready", status: "True" }],
    },
  };
}

test("buildClusterPressureSummary maps saturated workers to a simple status", () => {
  const summary = buildClusterPressureSummary({
    nodes: { items: [node("worker-1"), node("worker-2")] },
    pods: {
      items: [
        pod("api", "worker-1", { cpu: "1800m", memory: "7Gi" }),
        pod("db", "worker-2", { cpu: "1200m", memory: "2Gi" }),
      ],
    },
    topNodes: "NAME CPU(cores) CPU% MEMORY(bytes) MEMORY%\nworker-1 900m 45% 6Gi 75%\n",
    longhornNodes: {
      items: [
        {
          metadata: { name: "worker-1" },
          status: {
            diskStatus: {
              default: {
                storageMaximum: 100,
                storageScheduled: 91,
                conditions: [{ type: "Schedulable", status: "True" }],
              },
            },
          },
        },
      ],
    },
    longhornVolumes: { items: [] },
    events: { items: [{ type: "Warning" }, { type: "Warning" }] },
    generatedAt: "2026-08-23T18:15:00.000Z",
  });

  assert.equal(summary.summary.level, "very-busy");
  assert.equal(summary.summary.label, "Heel druk");
  assert.equal(summary.signals.find((entry) => entry.id === "compute").percent, 90);
  assert.equal(summary.signals.find((entry) => entry.id === "storage").level, "very-busy");
  assert.equal(summary.nodes[0].cpuRequestedPercent, 90);
});
