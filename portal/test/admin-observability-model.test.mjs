import test from "node:test";
import assert from "node:assert/strict";

import { buildObservabilityViewModel } from "../src/admin-observability-model.js";

test("buildObservabilityViewModel normalizes the active profile and keeps defaults intact", () => {
  const viewModel = buildObservabilityViewModel({
    config: {
      observability: {
        title: "Observability control",
        description: "Choose how much monitoring the cluster should carry.",
        footnote: "Metrics-server stays enabled in every mode so kubectl top keeps working.",
        profiles: {
          minimal: {
            summary: "Small-cluster mode",
            keeps: ["Kubernetes resource metrics"],
            removes: ["Grafana"],
            footprint: {
              cpu: "~0.2 core",
              memory: "~256 MiB",
              storage: "no long-lived observability PVCs",
            },
          },
          full: {
            summary: "Full monitoring stack",
            keeps: ["Dashboards"],
            removes: [],
          },
        },
      },
    },
    cluster: {
      id: "cluster-test",
      name: "twinbox-test",
      observability_profile: "minimal",
      observability_status: "applying",
      observability_error: null,
      observability_last_job_id: "job-123",
    },
    selectedProfile: "off",
  });

  assert.equal(viewModel.currentProfile, "minimal");
  assert.equal(viewModel.currentStatus, "applying");
  assert.equal(viewModel.currentStatusTone, "is-warning");
  assert.equal(viewModel.currentStatusLabel, "applying");
  assert.equal(viewModel.currentProfileCard.label, "Minimal");
  assert.equal(viewModel.selectedProfile, "off");
  assert.equal(viewModel.selectedProfileCard.priority, "destructive");
  assert.equal(viewModel.profiles.length, 3);
  assert.equal(viewModel.profiles.find((profile) => profile.id === "off")?.label, "Off");
  assert(viewModel.canChangeProfile);
});
