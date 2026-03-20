import test from 'node:test';
import assert from 'node:assert/strict';

import {
  getMissionControlModel,
  restoreUiState,
  serializeUiState,
} from '../src/journey.js';

const catalog = {
  categories: [
    {
      id: 'management-vm',
      title: 'Management VM',
      summary: 'Keep the management plane configured.',
      status: 'ready',
      steps: [
        {
          id: 'configure-automatic-updates',
          title: 'Configure automatic updates',
          type: 'config',
          journey_stage: 'manage',
          summary: 'Configure nightly updates.',
          explanation: 'Persist and apply the nightly policy.',
          side_help: 'Twinbox writes one managed cron file.',
          inputs: [
            { id: 'enabled', label: 'Enable nightly updates', type: 'boolean', default: true },
          ],
          depends_on: [],
          status: 'ready',
          state: {
            status: 'not_started',
            inputs: {},
            outputs: null,
            cluster_id: null,
            error: null,
            updated_at: null,
          },
          latest_job: null,
        },
      ],
    },
    {
      id: 'talos-cluster',
      title: 'Talos Cluster',
      summary: 'Provision and bootstrap the cluster.',
      status: 'ready',
      steps: [
        {
          id: 'provision-nodes',
          title: 'Provision nodes',
          type: 'action',
          journey_stage: 'setup',
          summary: 'Create the Talos nodes.',
          explanation: 'Provision the VM inventory.',
          side_help: 'Uses the existing Talos VM provisioning path.',
          inputs: [
            { id: 'name', label: 'Cluster name', type: 'string', default: 'twinbox-cluster' },
          ],
          depends_on: [],
          status: 'ready',
          state: {
            status: 'not_started',
            inputs: {},
            outputs: null,
            cluster_id: null,
            error: null,
            updated_at: null,
          },
          latest_job: null,
        },
        {
          id: 'bootstrap-cluster',
          title: 'Bootstrap cluster',
          type: 'action',
          journey_stage: 'setup',
          summary: 'Bootstrap the Talos control plane.',
          explanation: 'Apply the Talos configuration.',
          side_help: 'Waits for provisioning to finish.',
          inputs: [],
          depends_on: ['provision-nodes'],
          status: 'locked',
          state: {
            status: 'not_started',
            inputs: {},
            outputs: null,
            cluster_id: null,
            error: null,
            updated_at: null,
          },
          latest_job: null,
        },
      ],
    },
  ],
  errors: [],
};

test('mission control model exposes manifest-driven categories with locked dependencies', () => {
  const model = getMissionControlModel({
    catalog,
    logs: [],
    cluster: null,
    health: { ok: true },
    error: '',
    busy: false,
    selectedStepId: 'configure-automatic-updates',
  });

  assert.equal(model.categories.length, 2);
  assert.deepEqual(
    model.categories.map((category) => category.title),
    [
      'Management VM',
      'Talos Cluster',
    ],
  );
  assert.equal(model.activeStep.id, 'provision-nodes');
  assert.equal(model.activeStep.status, 'ready');
  assert.equal(model.activeCategory.title, 'Talos Cluster');
  assert.equal(model.nextStep.id, 'bootstrap-cluster');
  assert.equal(model.primaryAction.type, 'execute');
  assert.equal(model.categories[1].steps[1].status, 'locked');
  assert.equal(model.progress.totalSteps, 2);
  assert.equal(model.progress.completedSteps, 0);
});

test('mission model exposes guided setup mode and numbered actions', () => {
  const model = getMissionControlModel({
    catalog,
    logs: [],
    cluster: null,
    health: { ok: true },
    error: '',
    busy: false,
    selectedStepId: 'provision-nodes',
  });

  assert.equal(model.mode, 'setup');
  assert.equal(model.progress.stepIndex, 1);
  assert.equal(model.primaryAction.label, 'Start step 1');
  assert.equal(model.stepRail.length, 2);
  assert.equal(model.stepRail[0].isCurrent, true);
});

test('mission model labels the next action as continue when the current step is done', () => {
  const completedStepCatalog = structuredClone(catalog);
  completedStepCatalog.categories[1].steps[0].status = 'done';
  completedStepCatalog.categories[1].steps[0].state = {
    ...completedStepCatalog.categories[1].steps[0].state,
    status: 'succeeded',
  };

  const model = getMissionControlModel({
    catalog: completedStepCatalog,
    logs: [],
    cluster: { id: 'cluster_demo', status: 'provisioned' },
    health: { ok: true },
    error: '',
    busy: false,
    selectedStepId: 'provision-nodes',
  });

  assert.equal(model.mode, 'setup');
  assert.equal(model.primaryAction.label, 'Continue to step 2');
});

test('mission model labels the primary action as retry when a setup step fails', () => {
  const failedStepCatalog = structuredClone(catalog);
  failedStepCatalog.categories[1].steps[0].status = 'failed';
  failedStepCatalog.categories[1].steps[0].state = {
    ...failedStepCatalog.categories[1].steps[0].state,
    status: 'failed',
    error: 'provisioning failed',
  };

  const model = getMissionControlModel({
    catalog: failedStepCatalog,
    logs: [],
    cluster: null,
    health: { ok: true },
    error: '',
    busy: false,
    selectedStepId: 'provision-nodes',
  });

  assert.equal(model.mode, 'setup');
  assert.equal(model.primaryAction.label, 'Retry step 1');
});

test('mission model keeps manage-only steps out of the guided setup rail', () => {
  const model = getMissionControlModel({
    catalog,
    logs: [],
    cluster: null,
    health: { ok: true },
    error: '',
    busy: false,
    selectedStepId: '',
  });

  assert.equal(model.mode, 'setup');
  assert.equal(model.activeStep.id, 'provision-nodes');
  assert.equal(model.progress.totalSteps, 2);
  assert.equal(model.progress.stepIndex, 1);
  assert.deepEqual(
    model.stepRail.map((step) => step.id),
    ['provision-nodes', 'bootstrap-cluster'],
  );
  assert.equal(model.primaryAction.label, 'Start step 1');
});

test('mission model switches to manage mode when setup flow is complete', () => {
  const completedCatalog = structuredClone(catalog);
  completedCatalog.categories[1].steps[0].status = 'done';
  completedCatalog.categories[1].steps[0].state = {
    ...completedCatalog.categories[1].steps[0].state,
    status: 'succeeded',
  };
  completedCatalog.categories[1].steps[1].status = 'done';
  completedCatalog.categories[1].steps[1].state = {
    ...completedCatalog.categories[1].steps[1].state,
    status: 'succeeded',
  };

  const model = getMissionControlModel({
    catalog: completedCatalog,
    logs: [],
    cluster: { id: 'cluster_demo', status: 'bootstrapped' },
    health: { ok: true },
    error: '',
    busy: false,
    selectedStepId: 'configure-automatic-updates',
  });

  assert.equal(model.mode, 'manage');
  assert.equal(model.activeStep.id, 'configure-automatic-updates');
});

test('mission control model projects running and completed step state from catalog payload', () => {
  const runningCatalog = structuredClone(catalog);
  runningCatalog.categories[1].steps[0].status = 'done';
  runningCatalog.categories[1].steps[0].state = {
    status: 'succeeded',
    inputs: { name: 'demo' },
    outputs: { cluster_id: 'cluster_demo' },
    cluster_id: 'cluster_demo',
    error: null,
    updated_at: '2026-03-20T10:00:00Z',
  };
  runningCatalog.categories[1].steps[1].status = 'running';
  runningCatalog.categories[1].steps[1].latest_job = {
    id: 'job_bootstrap',
    type: 'run_step',
    status: 'running',
    step: 'started',
    error: null,
  };

  const model = getMissionControlModel({
    catalog: runningCatalog,
    logs: [{ line: '[2026-03-20T10:10:00Z] bootstrapping cluster' }],
    cluster: {
      id: 'cluster_demo',
      status: 'provisioned',
      controlplane_ips: ['192.168.1.51'],
      worker_ips: ['192.168.1.52', '192.168.1.53'],
      vip_ip: '192.168.1.50',
    },
    health: { ok: true },
    error: '',
    busy: false,
    selectedStepId: 'bootstrap-cluster',
  });

  assert.equal(model.activeStep.id, 'bootstrap-cluster');
  assert.equal(model.activeStep.status, 'running');
  assert.equal(model.previousStep.id, 'provision-nodes');
  assert.equal(model.primaryAction.disabled, true);
  assert.equal(model.progress.completedSteps, 1);
  assert.equal(model.activity.artifacts.find((artifact) => artifact.label === 'Cluster ID').value, 'cluster_demo');
  assert.equal(model.activity.runtime.currentStage, 'Bootstrapping cluster');
  assert.equal(model.activity.runtime.runState, 'running');
  assert.equal(model.activity.runtime.timelineEvents.length, 1);
  assert.match(model.activity.runtime.lastUpdatedLabel, /Updated/);
});

test('mission control model derives queued runtime state when no meaningful logs are present', () => {
  const queuedCatalog = structuredClone(catalog);
  queuedCatalog.categories[1].steps[0].status = 'running';
  queuedCatalog.categories[1].steps[0].latest_job = {
    id: 'job_queue',
    type: 'run_step',
    status: 'pending',
    step: 'queued',
    error: null,
    updated_at: '2026-03-20T10:09:00Z',
  };

  const model = getMissionControlModel({
    catalog: queuedCatalog,
    logs: [],
    cluster: null,
    health: { ok: true },
    error: '',
    busy: false,
    selectedStepId: 'provision-nodes',
  });

  assert.equal(model.activity.runtime.currentStage, 'Queued');
  assert.equal(model.activity.runtime.runState, 'pending');
  assert.equal(model.activity.runtime.timelineEvents[0].title, 'Queued');
});

test('mission control model derives provisioning and failure runtime events from logs', () => {
  const runningCatalog = structuredClone(catalog);
  runningCatalog.categories[1].steps[0].status = 'failed';
  runningCatalog.categories[1].steps[0].latest_job = {
    id: 'job_provision',
    type: 'run_step',
    status: 'failed',
    step: 'failed',
    error: 'command exited with code 1: Proxmox API POST failed',
    updated_at: '2026-03-20T10:12:00Z',
  };

  const model = getMissionControlModel({
    catalog: runningCatalog,
    logs: [
      { line: '[2026-03-20T10:11:55Z] queued run_step' },
      { line: '[2026-03-20T10:11:56Z] running job type=run_step' },
      { line: '[2026-03-20T10:11:58Z] [2026-03-20 10:11:58] Created controlplane VM twinbox-cluster-cp-1 (192.168.1.51)' },
      { line: '[2026-03-20T10:12:00Z] job failed: command exited with code 1: Proxmox API POST failed' },
    ],
    cluster: {
      id: 'cluster_demo',
      status: 'requested',
      vip_ip: '192.168.1.50',
    },
    health: { ok: true },
    error: '',
    busy: false,
    selectedStepId: 'provision-nodes',
  });

  assert.equal(model.activity.runtime.currentStage, 'Failed');
  assert.equal(model.activity.runtime.runState, 'failed');
  assert.equal(model.activity.runtime.timelineEvents.some((event) => event.title === 'Creating VMs'), true);
  assert.equal(model.activity.runtime.timelineEvents.at(-1).tone, 'danger');
});

test('ui state serialization restores the selected step preference', () => {
  const serialized = serializeUiState({
    selectedStepId: 'bootstrap-cluster',
  });

  const restored = restoreUiState(serialized);
  assert.equal(restored.selectedStepId, 'bootstrap-cluster');

  const fallback = restoreUiState('not-json');
  assert.equal(fallback.selectedStepId, '');
});
