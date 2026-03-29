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
    ['install-longhorn-storage', 'Install Longhorn storage', { dependsOn: ['provision-nodes'] }],
    ['install-secret-sync', 'Install OpenBao and sync bootstrap secrets', { dependsOn: ['install-longhorn-storage'] }],
    ['install-argocd', 'Install Argo CD', { dependsOn: ['install-secret-sync'] }],
    ['install-whoami', 'Install Whoami', { dependsOn: ['install-argocd'] }],
    ['install-headlamp', 'Install Headlamp', { dependsOn: ['install-whoami'] }],
    ['install-grafana', 'Install Grafana', { dependsOn: ['install-headlamp'] }],
    ['install-wiredoor-gateway', 'Install Wiredoor gateway', { dependsOn: ['install-grafana'] }],
    ['install-authentik-idp', 'Install Authentik IDP', { dependsOn: ['install-longhorn-storage'] }],
    ['create-users-and-groups', 'Create Users and Groups', { dependsOn: ['install-authentik-idp'] }],
    ['configure-cloudflare-dns', 'Configure Cloudflare DNS', { dependsOn: ['create-users-and-groups'] }],
    ['install-homepage-dashboard', 'Install Homepage dashboard', { dependsOn: ['install-wiredoor-gateway'] }],
    ['install-management-consoles', 'Install Management consoles', { dependsOn: ['install-homepage-dashboard'] }],
    ['install-velero-backup', 'Install Velero backup', { dependsOn: ['install-management-consoles'] }],
    ['install-proxmox-backup-system', 'Install Proxmox Backup System', { dependsOn: ['install-velero-backup'] }],
    ['install-nextcloud', 'Install Nextcloud', { dependsOn: ['install-proxmox-backup-system'] }],
    ['install-immich', 'Install Immich', { dependsOn: ['install-nextcloud'] }],
    ['install-rocketchat', 'Install Rocketchat', { dependsOn: ['install-immich'] }],
    ['install-paperless', 'Install Paperless', { dependsOn: ['install-rocketchat'] }],
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
  assert.equal(model.stepRail.length, 26);
  assert.equal(model.stepRail[0].title, 'Deploy Talos Cluster');
  assert.equal(model.stepRail[0].isCurrent, true);
  assert.equal(model.primaryAction.label, 'Start step 1');
  assert.equal(model.progress.totalSteps, 26);
  assert.equal(model.progress.completedSteps, 0);
  assert.equal(model.activity.runtime.currentStage, 'Applying cluster plan');
});

test('wizard model advances to the next step when the active step is done', () => {
  const model = getMissionControlModel({
    catalog: buildCatalog({
      'provision-nodes': 'done',
      'install-secret-sync': 'ready',
    }),
    logs: [],
    cluster: { id: 'cluster_demo', status: 'provisioned' },
    health: { ok: true },
    error: '',
    busy: false,
    selectedStepId: 'provision-nodes',
  });

  assert.equal(model.stepRail[0].isComplete, true);
  assert.equal(model.primaryAction.label, 'Continue to step 2');
  assert.equal(model.progress.completedSteps, 1);
  assert.equal(model.healthBadges.find((badge) => badge.id === 'cluster').value, 'cluster_demo');
});

test('wizard model switches to manage mode when setup flow is complete', () => {
  const completedCatalog = buildCatalog(
    Object.fromEntries(
      [
        'provision-nodes',
        'install-longhorn-storage',
        'install-secret-sync',
        'install-argocd',
        'install-whoami',
        'install-headlamp',
        'install-grafana',
        'install-wiredoor-gateway',
        'install-authentik-idp',
        'create-users-and-groups',
        'configure-cloudflare-dns',
        'install-homepage-dashboard',
        'install-management-consoles',
        'install-velero-backup',
        'install-proxmox-backup-system',
        'install-nextcloud',
        'install-immich',
        'install-rocketchat',
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
  assert.equal(model.primaryAction.label, 'Finish setup');
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

  assert.equal(model.stepRail.length, 26);
  assert.deepEqual(model.stepRail.map((step) => step.id), [
    'provision-nodes',
    'install-longhorn-storage',
    'install-secret-sync',
    'install-argocd',
    'install-whoami',
    'install-headlamp',
    'install-grafana',
    'install-wiredoor-gateway',
    'install-authentik-idp',
    'create-users-and-groups',
    'configure-cloudflare-dns',
    'install-homepage-dashboard',
    'install-management-consoles',
    'install-velero-backup',
    'install-proxmox-backup-system',
    'install-nextcloud',
    'install-immich',
    'install-rocketchat',
    'install-paperless',
    'install-karakeep',
    'install-gitea',
    'install-uptimekuma',
    'install-n8n',
    'install-audiobookshelf',
    'install-freshrss',
    'install-jitsi',
  ]);
});

test('wizard export and import helpers round-trip answers and cluster ids', () => {
  const serialized = serializeUiState({
    selectedStepId: 'install-secret-sync',
    clusterId: 'cluster_demo',
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
  assert.equal(restored.answers['provision-nodes'].name, 'demo');
  assert.deepEqual(restored.answers['provision-nodes'].vm_node_map, {
    'cp-1': 'pve-a',
  });

  const fallback = restoreUiState('not-json');
  assert.equal(fallback.selectedStepId, '');
  assert.equal(fallback.clusterId, '');
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
