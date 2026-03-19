import test from 'node:test';
import assert from 'node:assert/strict';

import {
  defaultForm,
  getMissionControlModel,
  restoreMissionState,
  serializeMissionState,
} from '../src/journey.js';

test('mission control model exposes dependency-ordered phases with guided gating', () => {
  const model = getMissionControlModel({
    form: defaultForm,
    completedStepIds: [],
    cluster: null,
    job: null,
    logs: [],
    health: { ok: true },
    selectedStepId: 'foundation-overview',
  });

  assert.equal(model.phases.length, 9);
  assert.deepEqual(
    model.phases.map((phase) => phase.title),
    [
      'Foundation',
      'Talos Cluster',
      'Core Networking',
      'Identity & Access',
      'Storage & Backups',
      'GitOps & Platform Services',
      'Applications',
      'Hardening & Operations',
      'Go Live',
    ],
  );

  assert.equal(model.activeStep.id, 'foundation-overview');
  assert.equal(model.activeStep.status, 'ready');
  assert.equal(model.activePhase.title, 'Foundation');
  assert.equal(model.nextStep.id, 'foundation-cluster-profile');
  assert.equal(model.canAdvance, true);
  assert.equal(model.phases[1].status, 'locked');
});

test('mission control model projects runtime into running, failed, done, and blocked steps', () => {
  const completedStepIds = [
    'foundation-overview',
    'foundation-cluster-profile',
    'foundation-network-plan',
  ];

  const runningModel = getMissionControlModel({
    form: defaultForm,
    completedStepIds,
    cluster: {
      id: 'cluster_twinbox',
      status: 'requested',
      metadata: { proxmox_node: 'pve' },
    },
    job: {
      id: 'job_create',
      type: 'create_cluster',
      status: 'running',
      step: 'started',
    },
    logs: [{ line: '[2026-03-19T10:00:00Z] creating control plane VMs' }],
    health: { ok: true },
  });

  assert.equal(runningModel.activeStep.id, 'talos-provision');
  assert.equal(runningModel.activeStep.status, 'running');
  assert.equal(runningModel.phases[1].status, 'running');

  const failedModel = getMissionControlModel({
    form: defaultForm,
    completedStepIds,
    cluster: {
      id: 'cluster_twinbox',
      status: 'provisioned',
      metadata: { proxmox_node: 'pve' },
      controlplane_ips: ['192.168.1.51'],
      worker_ips: ['192.168.1.52', '192.168.1.53'],
      vip_ip: '192.168.1.50',
    },
    job: {
      id: 'job_bootstrap',
      type: 'bootstrap_cluster',
      status: 'failed',
      step: 'failed',
      error: 'Talos API did not answer in time',
    },
    logs: [{ line: '[2026-03-19T10:05:00Z] job failed: Talos API did not answer in time' }],
    health: { ok: true },
    selectedStepId: 'talos-bootstrap',
  });

  assert.equal(failedModel.activeStep.id, 'talos-bootstrap');
  assert.equal(failedModel.activeStep.status, 'failed');
  assert.equal(failedModel.canAdvance, false);

  const bootstrappedModel = getMissionControlModel({
    form: defaultForm,
    completedStepIds,
    cluster: {
      id: 'cluster_twinbox',
      status: 'bootstrapped',
      metadata: { proxmox_node: 'pve' },
      controlplane_ips: ['192.168.1.51'],
      worker_ips: ['192.168.1.52', '192.168.1.53'],
      talos_config_dir: '/data/talos/cluster_twinbox',
      vip_ip: '192.168.1.50',
    },
    job: {
      id: 'job_bootstrap',
      type: 'bootstrap_cluster',
      status: 'succeeded',
      step: 'completed',
    },
    logs: [{ line: '[2026-03-19T10:10:00Z] talos bootstrap completed' }],
    health: { ok: true },
  });

  assert.equal(bootstrappedModel.steps.find((step) => step.id === 'talos-provision').status, 'done');
  assert.equal(bootstrappedModel.steps.find((step) => step.id === 'talos-bootstrap').status, 'done');
  assert.equal(bootstrappedModel.activeStep.id, 'talos-validate');
  assert.equal(bootstrappedModel.activeStep.status, 'ready');
  assert.equal(bootstrappedModel.healthBadges.find((badge) => badge.id === 'talos').tone, 'success');

  const blockedModel = getMissionControlModel({
    form: defaultForm,
    completedStepIds: [...completedStepIds, 'talos-validate'],
    cluster: {
      id: 'cluster_twinbox',
      status: 'bootstrapped',
      metadata: { proxmox_node: 'pve' },
      controlplane_ips: ['192.168.1.51'],
      worker_ips: ['192.168.1.52', '192.168.1.53'],
      talos_config_dir: '/data/talos/cluster_twinbox',
      vip_ip: '192.168.1.50',
    },
    job: null,
    logs: [],
    health: { ok: true },
  });

  assert.equal(blockedModel.activePhase.title, 'Core Networking');
  assert.equal(blockedModel.activeStep.id, 'networking-load-balancer');
  assert.equal(blockedModel.activeStep.status, 'blocked');
});

test('mission control state serialization restores the exact working context', () => {
  const serialized = serializeMissionState({
    form: {
      ...defaultForm,
      name: 'production',
      vip_ip: '10.0.0.40',
    },
    completedStepIds: ['foundation-overview', 'foundation-cluster-profile'],
    selectedStepId: 'foundation-network-plan',
    clusterId: 'cluster_prod',
    jobId: 'job_prod',
  });

  const restored = restoreMissionState(serialized);
  assert.equal(restored.form.name, 'production');
  assert.equal(restored.form.vip_ip, '10.0.0.40');
  assert.deepEqual(restored.completedStepIds, ['foundation-overview', 'foundation-cluster-profile']);
  assert.equal(restored.selectedStepId, 'foundation-network-plan');
  assert.equal(restored.clusterId, 'cluster_prod');
  assert.equal(restored.jobId, 'job_prod');

  const fallback = restoreMissionState('not-json');
  assert.deepEqual(fallback.completedStepIds, []);
  assert.equal(fallback.selectedStepId, 'foundation-overview');
});
