import test from 'node:test';
import assert from 'node:assert/strict';

import {
  buildWizardExportFilename,
  getMissionControlModel,
  restoreUiState,
  serializeUiState,
} from '../src/journey.js';

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
  const setupSteps = [
    ['provision-nodes', 'Deploy Talos Cluster', { status: 'ready', dependsOn: [] }],
    ['install-argocd', 'Install Argo CD', { dependsOn: ['provision-nodes'] }],
    ['install-longhorn-storage', 'Install Longhorn storage', { dependsOn: ['install-argocd'] }],
    ['install-secret-sync', 'Install OpenBao and sync bootstrap secrets', { dependsOn: ['install-longhorn-storage'] }],
    ['install-traefik', 'Install Traefik', { dependsOn: ['install-secret-sync'] }],
    ['install-cloudnativepg', 'Install CloudNativePG', { dependsOn: ['install-argocd', 'install-longhorn-storage'] }],
    ['install-authentik-idp', 'Install Authentik', { dependsOn: ['install-secret-sync', 'install-longhorn-storage', 'install-cloudnativepg', 'install-traefik', 'choose-ingress-route'] }],
    ['create-users-and-groups', 'Create Users and Groups', { dependsOn: ['install-authentik-idp'] }],
    ['choose-ingress-route', 'Choose Ingress Route', { dependsOn: ['create-users-and-groups'] }],
    ['install-whoami', 'Install Whoami', { dependsOn: ['install-traefik'] }],
    ['install-headlamp', 'Install Headlamp', { dependsOn: ['install-whoami'] }],
    ['install-grafana', 'Install Grafana', { dependsOn: ['install-headlamp'] }],
    ['install-loki', 'Install Loki', { dependsOn: ['install-prometheus', 'install-longhorn-storage'] }],
    ['install-dashy-dashboard', 'Install Dashy dashboard', { dependsOn: ['install-grafana'] }],
    ['install-management-consoles', 'Install Management consoles', { dependsOn: ['install-dashy-dashboard'] }],
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
    ['install-proxmox-backup-system', 'Install Proxmox Backup System', { dependsOn: ['install-velero-backup'] }],
    ['install-nextcloud', 'Install Nextcloud', { dependsOn: ['install-proxmox-backup-system'] }],
    ['install-immich', 'Install Immich', { dependsOn: ['install-nextcloud'] }],
    ['install-zulip', 'Install Zulip', { dependsOn: ['install-immich'] }],
    ['install-paperless', 'Install Paperless', { dependsOn: ['install-zulip'] }],
    ['install-karakeep', 'Install Karakeep', { dependsOn: ['install-paperless'] }],
    ['install-gitea', 'Install Gitea', { dependsOn: ['install-karakeep'] }],
    ['install-uptimekuma', 'Install Uptimekuma', { dependsOn: ['install-gitea'] }],
    ['install-n8n', 'Install N8N', { dependsOn: ['install-uptimekuma'] }],
    ['install-audiobookshelf', 'Install Audiobookshelf', { dependsOn: ['install-n8n'] }],
    ['install-freshrss', 'Install FreshRss', { dependsOn: ['install-audiobookshelf'] }],
    ['install-jitsi', 'Install Jitsi', { dependsOn: ['install-freshrss'] }],
  ].map(([id, title, options]) => ({
    ...makeStep(id, title, options),
    status: stepStatuses[id] ?? options.status ?? 'locked',
  }));

  return {
    categories: [
      {
        id: 'management-vm',
        title: 'Management VM',
        summary: 'Keep the management plane configured.',
        status: 'ready',
        steps: [
          makeStep('configure-automatic-updates', 'Configure automatic updates', {
            journeyStage: 'manage',
            status: 'ready',
            summary: 'Configure nightly updates.',
            explanation: 'Persist and apply the nightly policy.',
            sideHelp: 'Twinbox writes one managed cron file.',
          }),
        ],
      },
      {
        id: 'talos-cluster',
        title: 'Talos Cluster',
        summary: 'Deploy the cluster end to end.',
        status: 'ready',
        steps: setupSteps,
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
  assert.equal(model.stepRail.length, 30);
  const stepRailById = Object.fromEntries(model.stepRail.map((step) => [step.id, step]));
  assert.equal(stepRailById['provision-nodes'].title, 'Deploy Talos Cluster');
  assert.equal(stepRailById['provision-nodes'].isCurrent, true);
  assert.equal(stepRailById['provision-nodes'].icon, '🖥️');
  assert.equal(stepRailById['provision-nodes'].project_url, 'https://www.talos.dev/');
  assert.equal(stepRailById['provision-nodes'].github_url, 'https://github.com/siderolabs/talos');
  assert.match(stepRailById['provision-nodes'].positive_summary, /Twinbox stages/);
  assert.equal(stepRailById['install-cloudnativepg'].title, 'Install CloudNativePG');
  assert.equal(stepRailById['install-cloudnativepg'].icon, '🐘');
  assert.equal(stepRailById['install-pgadmin4'].title, 'Install pgAdmin 4');
  assert.equal(stepRailById['install-pgadmin4'].icon, '🗃️');
  assert.equal(model.primaryAction.label, 'Next');
  assert.equal(model.progress.totalSteps, 30);
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
        'install-traefik',
        'install-cloudnativepg',
        'create-users-and-groups',
        'install-whoami',
        'install-headlamp',
        'install-grafana',
        'install-loki',
        'install-pgadmin4',
        'install-dashy-dashboard',
        'install-management-consoles',
        'install-ntfy',
        'install-velero-backup',
        'install-proxmox-backup-system',
        'install-nextcloud',
        'install-immich',
        'install-zulip',
        'install-paperless',
        'install-karakeep',
        'install-gitea',
        'install-uptimekuma',
        'install-n8n',
        'install-audiobookshelf',
        'install-freshrss',
        'install-jitsi',
      ].map((id) => [id, 'done']),
    ),
  );

  completedCatalog.categories[1].steps = completedCatalog.categories[1].steps.map((step) =>
    step.id === 'choose-ingress-route'
      ? { ...step, status: 'configured' }
      : step,
  );

  const model = getMissionControlModel({
    catalog: completedCatalog,
    logs: [],
    cluster: { id: 'cluster_demo', status: 'bootstrapped' },
    health: { ok: true },
    error: '',
    busy: false,
    selectedStepId: 'install-jitsi',
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

  assert.equal(model.stepRail.length, 30);
  const setupStepIds = new Set(model.stepRail.map((step) => step.id));
  for (const id of [
    'provision-nodes',
    'install-argocd',
    'install-longhorn-storage',
    'install-secret-sync',
    'install-traefik',
    'install-cloudnativepg',
    'install-authentik-idp',
    'create-users-and-groups',
    'choose-ingress-route',
    'install-whoami',
    'install-headlamp',
    'install-grafana',
    'install-dashy-dashboard',
    'install-ntfy',
    'install-management-consoles',
    'install-velero-backup',
    'install-proxmox-backup-system',
    'install-nextcloud',
    'install-immich',
    'install-zulip',
    'install-paperless',
    'install-karakeep',
    'install-gitea',
    'install-uptimekuma',
    'install-n8n',
    'install-audiobookshelf',
    'install-freshrss',
    'install-jitsi',
  ]) {
    assert.equal(setupStepIds.has(id), true);
  }
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

test('wizard export filename uses the cluster name and date', () => {
  const filename = buildWizardExportFilename({
    clusterName: 'Demo Cluster',
    clusterId: 'cluster_demo',
    date: new Date('2026-03-27T10:00:00Z'),
  });

  assert.equal(filename, 'twinbox-demo-cluster-2026-03-27.json');
});
