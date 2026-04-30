import test from 'node:test';
import assert from 'node:assert/strict';

import {
  buildWizardExportFilename,
  getNextInstallableSetupStep,
  getMissionControlModel,
  getWizardPhaseBoundaries,
  restoreUiState,
  serializeUiState,
} from '../src/journey.js';
import { normalizeLogEntries } from '../src/install-logs.js';

function makeStep(id, title, {
  journeyStage = 'setup',
  status = 'locked',
  dependsOn = [],
  summary = `${title} placeholder.`,
  explanation = `Placeholder step for ${title}.`,
  sideHelp = `Placeholder step for ${title}.`,
} = {}) {
  return {
    id,
    title,
    type: journeyStage === 'manage' ? 'config' : 'action',
    journey_stage: journeyStage,
    summary,
    explanation,
    side_help: sideHelp,
    inputs: [],
    depends_on: dependsOn,
    status,
    state: {
      status: 'not_started',
      inputs: {},
      outputs: null,
      cluster_id: null,
      error: null,
      updated_at: null,
    },
    latest_job: null,
  };
}

function buildCatalog(stepStatuses = {}) {
  const coreSetupSteps = [
    ['provision-nodes', 'Deploy Talos Cluster', { status: 'ready', dependsOn: [] }],
    ['install-argocd', 'Install Argo CD', { dependsOn: ['provision-nodes'] }],
    ['install-longhorn-storage', 'Install Longhorn storage', { dependsOn: ['install-argocd'] }],
    ['install-secret-sync', 'Install OpenBao and sync bootstrap secrets', { dependsOn: ['install-longhorn-storage'] }],
    ['install-crowdsec', 'Install CrowdSec', { dependsOn: ['install-secret-sync'] }],
    ['install-traefik', 'Install Traefik', { dependsOn: ['install-crowdsec'] }],
    ['install-cloudnativepg', 'Install CloudNativePG', { dependsOn: ['install-argocd', 'install-longhorn-storage'] }],
    ['install-authentik-idp', 'Install Authentik', { dependsOn: ['install-secret-sync', 'install-longhorn-storage', 'install-cloudnativepg', 'install-traefik', 'choose-ingress-route'] }],
    ['create-users-and-groups', 'Create Users and Groups', { dependsOn: ['install-authentik-idp'] }],
    ['choose-ingress-route', 'Choose Ingress Route', { dependsOn: ['create-users-and-groups'] }],
    ['install-headlamp', 'Install Headlamp', { dependsOn: ['install-traefik'] }],
    ['install-prometheus', 'Install Prometheus', { dependsOn: ['install-headlamp'] }],
    ['install-loki', 'Install Loki', { dependsOn: ['install-prometheus', 'install-longhorn-storage'] }],
    ['install-tempo', 'Install Tempo', { dependsOn: ['install-longhorn-storage'] }],
    ['install-alloy', 'Install Alloy', { dependsOn: ['install-loki', 'install-tempo'] }],
    ['install-grafana', 'Install Grafana', {
      dependsOn: [
        'install-prometheus',
        'install-cloudnativepg',
        'install-secret-sync',
        'install-authentik-idp',
        'install-loki',
        'install-tempo',
        'install-alloy',
      ],
    }],
    ['install-dashy-dashboard', 'Install Dashy dashboard', { dependsOn: ['install-grafana'] }],
    ['install-twinbox-portal', 'Install Twinbox Portal', { dependsOn: ['install-dashy-dashboard'] }],
    ['install-management-consoles', 'Install Management consoles', { dependsOn: ['install-dashy-dashboard', 'install-twinbox-portal'] }],
    ['install-pgadmin4', 'Install pgAdmin 4', {
      dependsOn: [
        'install-secret-sync',
        'install-authentik-idp',
        'create-users-and-groups',
        'choose-ingress-route',
      ],
    }],
    ['install-ntfy', 'Install Ntfy', { dependsOn: ['install-dashy-dashboard'] }],
    ['install-velero-backup', 'Install Velero backup', { dependsOn: ['install-management-consoles', 'install-longhorn-storage', 'install-secret-sync'] }],
    ['install-velero-ui', 'Install Velero UI', { dependsOn: ['install-velero-backup', 'install-authentik-idp', 'create-users-and-groups', 'choose-ingress-route'] }],
  ].map(([id, title, options]) => ({
    ...makeStep(id, title, options),
    status: stepStatuses[id] ?? options.status ?? 'locked',
  }));

  const appSteps = [
    ['install-nextcloud', 'Install Nextcloud', { dependsOn: [] }],
    ['install-opencloud', 'Install OpenCloud', { dependsOn: ['install-longhorn-storage', 'install-secret-sync', 'install-authentik-idp', 'create-users-and-groups', 'choose-ingress-route'] }],
    ['install-immich', 'Install Immich', { dependsOn: ['install-longhorn-storage', 'install-cloudnativepg', 'install-secret-sync', 'install-authentik-idp', 'choose-ingress-route'] }],
    ['install-zulip', 'Install Zulip', { dependsOn: [] }],
    ['install-paperless', 'Install Paperless', { dependsOn: [] }],
    ['install-karakeep', 'Install Karakeep', {
      dependsOn: [
        'install-longhorn-storage',
        'install-secret-sync',
        'install-authentik-idp',
        'choose-ingress-route',
      ],
    }],
    ['install-vaultwarden', 'Install Vaultwarden', {
      dependsOn: [
        'install-longhorn-storage',
        'install-cloudnativepg',
        'install-secret-sync',
        'choose-ingress-route',
      ],
    }],
    ['install-n8n', 'Install N8N', {
      dependsOn: [
        'install-longhorn-storage',
        'install-cloudnativepg',
        'install-secret-sync',
        'choose-ingress-route',
      ],
    }],
    ['install-audiobookshelf', 'Install Audiobookshelf', {
      dependsOn: [
        'install-longhorn-storage',
        'install-secret-sync',
        'install-authentik-idp',
        'create-users-and-groups',
        'choose-ingress-route',
      ],
    }],
    ['install-freshrss', 'Install FreshRSS', { dependsOn: [] }],
    ['install-jitsi', 'Install Jitsi', { dependsOn: ['install-secret-sync', 'install-authentik-idp', 'create-users-and-groups', 'choose-ingress-route'] }],
  ].map(([id, title, options]) => ({
    ...makeStep(id, title, options),
    status: stepStatuses[id] ?? options.status ?? 'locked',
  }));

  return {
    categories: [
      {
        id: 'talos-cluster',
        title: 'Talos Cluster',
        summary: 'Deploy the cluster end to end.',
        status: 'ready',
        steps: coreSetupSteps,
      },
      {
        id: 'apps',
        title: 'Apps',
        summary: 'Install user-facing applications and collaboration tools.',
        status: 'ready',
        steps: appSteps,
      },
    ],
    errors: [],
  };
}

test('wizard model exposes a linear setup rail and guided actions', () => {
  const model = getMissionControlModel({
    catalog: buildCatalog({ 'provision-nodes': 'ready' }),
    logs: [{ line: '[2026-03-20T10:10:00Z] Applying OpenTofu cluster plan' }],
    cluster: null,
    health: { ok: true },
    error: '',
    busy: false,
    selectedStepId: 'provision-nodes',
  });

  assert.equal(model.mode, 'setup');
  assert.equal(model.stepRail.length, 23);
  const stepRailById = Object.fromEntries(model.stepRail.map((step) => [step.id, step]));
  assert.equal(stepRailById['provision-nodes'].title, 'Deploy Talos Cluster');
  assert.equal(stepRailById['provision-nodes'].isCurrent, true);
  assert.equal(stepRailById['provision-nodes'].icon, '🖥️');
  assert.equal(stepRailById['provision-nodes'].project_url, 'https://www.talos.dev/');
  assert.equal(stepRailById['provision-nodes'].github_url, 'https://github.com/siderolabs/talos');
  assert.match(stepRailById['provision-nodes'].positive_summary, /Twinbox stages/);
  assert.equal(stepRailById['install-cloudnativepg'].title, 'Install CloudNativePG');
  assert.equal(stepRailById['install-cloudnativepg'].icon, '🐘');
  assert.equal(stepRailById['install-tempo'].title, 'Install Tempo');
  assert.equal(stepRailById['install-tempo'].icon, '⏱️');
  assert.equal(stepRailById['install-alloy'].title, 'Install Alloy');
  assert.equal(stepRailById['install-alloy'].icon, '🧵');
  assert.equal(stepRailById['install-pgadmin4'].title, 'Install pgAdmin 4');
  assert.equal(stepRailById['install-pgadmin4'].icon, '🗃️');
  assert.equal(stepRailById['install-velero-ui'].title, 'Install Velero UI');
  assert.equal(stepRailById['install-velero-ui'].icon, '🖥️');
  assert.equal(model.primaryAction.label, 'Next');
  assert.equal(model.progress.totalSteps, 23);
  assert.equal(model.progress.completedSteps, 0);
  assert.equal(model.activity.runtime.currentStage, 'Applying cluster plan');
  assert.equal(model.activity.rawLogOutput, '[2026-03-20T10:10:00Z] Applying OpenTofu cluster plan');
});

test('wizard model keeps raw log output empty until the step has logs', () => {
  const model = getMissionControlModel({
    catalog: buildCatalog({ 'provision-nodes': 'ready' }),
    logs: [],
    cluster: null,
    health: { ok: true },
    error: '',
    busy: false,
    selectedStepId: 'provision-nodes',
  });

  assert.equal(model.activity.rawLogOutput, '');
});

test('wizard model renders log lines from both string and object log entries', () => {
  const model = getMissionControlModel({
    catalog: buildCatalog({ 'provision-nodes': 'ready' }),
    logs: [
      '[2026-03-20T10:10:00Z] raw string line ',
      { line: '[2026-03-20T10:11:00Z] object line ' },
      { message: 'ignored' },
    ],
    cluster: null,
    health: { ok: true },
    error: '',
    busy: false,
    selectedStepId: 'provision-nodes',
  });

  assert.equal(model.activity.rawLogOutput, '[2026-03-20T10:10:00Z] raw string line \n[2026-03-20T10:11:00Z] object line ');
});

test('normalizeLogEntries keeps the install log shape stable', () => {
  assert.deepEqual(normalizeLogEntries([
    '[ts] first ',
    { line: '[ts] second ' },
    { line: '' },
    null,
    { message: 'ignored' },
  ]), ['[ts] first ', '[ts] second ']);
});

test('wizard model advances to the next step when the active step is done', () => {
  const model = getMissionControlModel({
    catalog: buildCatalog({
      'provision-nodes': 'done',
    }),
    logs: [],
    cluster: { id: 'cluster_demo', status: 'provisioned' },
    health: { ok: true },
    error: '',
    busy: false,
    selectedStepId: 'provision-nodes',
  });

  const stepRailById = Object.fromEntries(model.stepRail.map((step) => [step.id, step]));
  assert.equal(stepRailById['provision-nodes'].isComplete, true);
  assert.equal(model.primaryAction.label, 'Next');
  assert.equal(model.progress.completedSteps, 1);
  assert.equal(model.healthBadges.find((badge) => badge.id === 'cluster').value, 'cluster_demo');
  assert.equal(stepRailById['install-argocd'].icon, '🔁');
});

test('wizard model switches to manage mode when setup flow is complete', () => {
  const completedCatalog = buildCatalog(
    Object.fromEntries(
      [
        'install-authentik-idp',
        'provision-nodes',
        'install-argocd',
        'install-longhorn-storage',
        'install-secret-sync',
        'install-crowdsec',
        'install-traefik',
        'install-cloudnativepg',
        'create-users-and-groups',
        'install-headlamp',
        'install-prometheus',
        'install-loki',
        'install-tempo',
        'install-alloy',
        'install-grafana',
        'install-pgadmin4',
        'install-dashy-dashboard',
        'install-twinbox-portal',
        'install-management-consoles',
        'install-ntfy',
        'install-velero-backup',
        'install-velero-ui',
        'install-nextcloud',
        'install-opencloud',
        'install-immich',
      ].map((id) => [id, 'done']),
    ),
  );

  completedCatalog.categories[0].steps = completedCatalog.categories[0].steps.map((step) =>
    step.id === 'choose-ingress-route'
      ? { ...step, status: 'configured' }
      : step,
  );
  completedCatalog.categories[0].steps.push(
    makeStep('manage-host-maintenance', 'Manage host maintenance', {
      journeyStage: 'manage',
      status: 'ready',
      summary: 'Configure nightly updates.',
      explanation: 'Persist and apply the nightly policy.',
      sideHelp: 'Twinbox writes one managed cron file.',
    }),
  );

  const model = getMissionControlModel({
    catalog: completedCatalog,
    logs: [],
    cluster: { id: 'cluster_demo', status: 'bootstrapped' },
    health: { ok: true },
    error: '',
    busy: false,
    selectedStepId: 'install-velero-ui',
  });

  assert.equal(model.mode, 'manage');
  assert.equal(model.primaryAction.label, 'Finish');
  assert.equal(model.completion.title, 'Cluster bootstrap complete');
});

test('wizard model keeps manage-only steps out of the setup rail', () => {
  const model = getMissionControlModel({
    catalog: buildCatalog({ 'provision-nodes': 'ready' }),
    logs: [],
    cluster: null,
    health: { ok: true },
    error: '',
    busy: false,
    selectedStepId: '',
  });

  assert.equal(model.stepRail.length, 23);
  const setupStepIds = new Set(model.stepRail.map((step) => step.id));
  for (const id of [
    'provision-nodes',
    'install-argocd',
    'install-longhorn-storage',
    'install-secret-sync',
    'install-crowdsec',
    'install-traefik',
    'install-cloudnativepg',
    'install-authentik-idp',
    'create-users-and-groups',
    'choose-ingress-route',
    'install-headlamp',
    'install-prometheus',
    'install-dashy-dashboard',
    'install-twinbox-portal',
    'install-ntfy',
    'install-management-consoles',
    'install-velero-backup',
    'install-velero-ui',
    'install-loki',
    'install-tempo',
    'install-alloy',
    'install-grafana',
  ]) {
    assert.equal(setupStepIds.has(id), true);
  }
});

test('next installable step recomputes visibility after the ingress choice changes', () => {
  const catalog = {
    categories: [
      {
        id: 'talos-cluster',
        title: 'Talos Cluster',
        summary: 'Deploy the cluster end to end.',
        status: 'ready',
        steps: [
          {
            ...makeStep('choose-ingress-route', 'Choose Ingress Route', {
              status: 'configured',
            }),
          },
          {
            ...makeStep('configure-cloudflare-tunnel', 'Configure Cloudflare Tunnel', {
              dependsOn: ['choose-ingress-route'],
            }),
            ingress_route: 'cloudflare-tunnel',
          },
        ],
      },
    ],
    errors: [],
  };

  const initialNextStep = getNextInstallableSetupStep(
    catalog,
    {},
    'choose-ingress-route',
    new Set(['choose-ingress-route']),
  );
  assert.equal(initialNextStep, null);

  const updatedNextStep = getNextInstallableSetupStep(
    catalog,
    {
      'choose-ingress-route': {
        ingress_route: 'cloudflare-tunnel',
      },
    },
    'choose-ingress-route',
    new Set(['choose-ingress-route']),
  );
  assert.equal(updatedNextStep?.id, 'configure-cloudflare-tunnel');
});

test('wizard model defaults to step 1 when nothing is selected', () => {
  const model = getMissionControlModel({
    catalog: buildCatalog({ 'provision-nodes': 'ready' }),
    logs: [],
    cluster: null,
    health: { ok: true },
    error: '',
    busy: false,
    selectedStepId: '',
  });

  assert.equal(model.activeStep.id, 'provision-nodes');
  assert.equal(model.stepRail.find((step) => step.id === 'provision-nodes')?.isCurrent, true);
  assert.equal(model.primaryAction.label, 'Next');
});

test('wizard phase boundaries expose the handoff points between questions and installs', () => {
  const boundaries = getWizardPhaseBoundaries(
    [
      { id: 'provision-nodes', title: 'Deploy Talos Cluster' },
      { id: 'choose-ingress-route', title: 'Choose Ingress Route' },
      { id: 'create-users-and-groups', title: 'Create Users and Groups' },
    ],
    [
      { id: 'provision-nodes', title: 'Deploy Talos Cluster' },
      { id: 'install-argocd', title: 'Install Argo CD' },
      { id: 'install-immich', title: 'Install Immich' },
    ],
  );

  assert.equal(boundaries.firstQuestionStep?.id, 'provision-nodes');
  assert.equal(boundaries.lastQuestionStep?.id, 'create-users-and-groups');
  assert.equal(boundaries.firstInstallStep?.id, 'provision-nodes');
  assert.equal(boundaries.lastInstallStep?.id, 'install-immich');
});

test('wizard ui state persists the selected phase alongside the active step', () => {
  const snapshot = serializeUiState({
    selectedStepId: 'provision-nodes',
    wizardPhase: 'install',
    answers: {
      'provision-nodes': {
        scale_percent: 90,
      },
    },
  });

  const restored = restoreUiState(snapshot);

  assert.equal(restored.selectedStepId, 'provision-nodes');
  assert.equal(restored.wizardPhase, 'install');
  assert.deepEqual(restored.answers, {
    'provision-nodes': {
      scale_percent: 90,
    },
  });
});

test('wizard model falls back to step 1 when a restored selection no longer exists', () => {
  const model = getMissionControlModel({
    catalog: buildCatalog({ 'provision-nodes': 'ready' }),
    logs: [],
    cluster: null,
    health: { ok: true },
    error: '',
    busy: false,
    selectedStepId: 'missing-step',
  });

  assert.equal(model.activeStep.id, 'provision-nodes');
  assert.equal(model.primaryAction.label, 'Next');
});

test('wizard export and import helpers round-trip answers and cluster ids', () => {
  const serialized = serializeUiState({
    selectedStepId: 'install-secret-sync',
    clusterId: 'cluster_demo',
    clusterCreatedAt: '2026-03-30T00:00:00Z',
    clusterInstanceId: '11111111-1111-1111-1111-111111111111',
    answers: {
      'provision-nodes': {
        name: 'demo',
        vip_ip: '192.168.1.50',
        vm_node_map: {
          'cp-1': 'pve-a',
        },
      },
    },
  });

  const restored = restoreUiState(serialized);
  assert.equal(restored.selectedStepId, 'install-secret-sync');
  assert.equal(restored.clusterId, 'cluster_demo');
  assert.equal(restored.clusterCreatedAt, '2026-03-30T00:00:00Z');
  assert.equal(restored.clusterInstanceId, '11111111-1111-1111-1111-111111111111');
  assert.equal(restored.answers['provision-nodes'].name, 'demo');
  assert.deepEqual(restored.answers['provision-nodes'].vm_node_map, {
    'cp-1': 'pve-a',
  });

  const fallback = restoreUiState('not-json');
  assert.equal(fallback.selectedStepId, '');
  assert.equal(fallback.clusterId, '');
  assert.equal(fallback.clusterCreatedAt, '');
  assert.equal(fallback.clusterInstanceId, '');
  assert.deepEqual(fallback.answers, {});
});

test('wizard restore helper defaults to a clean state when no storage is provided', () => {
  const restored = restoreUiState(null);

  assert.equal(restored.selectedStepId, '');
  assert.equal(restored.clusterId, '');
  assert.equal(restored.clusterCreatedAt, '');
  assert.equal(restored.clusterInstanceId, '');
  assert.deepEqual(restored.answers, {});
  assert.deepEqual(restored.installLogSnapshot, { stepId: '', output: '' });
});

test('wizard export filename uses the cluster name and date', () => {
  const filename = buildWizardExportFilename({
    clusterName: 'Demo Cluster',
    clusterId: 'cluster_demo',
    date: new Date('2026-03-27T10:00:00Z'),
  });

  assert.equal(filename, 'twinbox-demo-cluster-2026-03-27.json');
});
