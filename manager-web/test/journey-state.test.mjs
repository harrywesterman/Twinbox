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
  assert.equal(model.activeStep.id, 'configure-automatic-updates');
  assert.equal(model.activeStep.status, 'ready');
  assert.equal(model.activeCategory.title, 'Management VM');
  assert.equal(model.nextStep.id, 'provision-nodes');
  assert.equal(model.primaryAction.type, 'execute');
  assert.equal(model.categories[1].steps[1].status, 'locked');
  assert.equal(model.progress.totalSteps, 3);
  assert.equal(model.progress.completedSteps, 0);
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
