import test from 'node:test';
import assert from 'node:assert/strict';

import {
  buildAdminAppInstallPath,
  buildBundleInstallQueue,
  buildBundleInstallSummary,
  getAdminAppInstallButtonState,
  isAdminAppInstallEnabled,
  parseAdminAppInstallPath,
  resolveAdminCardIconUrl,
} from '../src/admin-apps-install.js';

test('admin app install routes round-trip for apps and bundles', () => {
  const appPath = buildAdminAppInstallPath('app', 'install-immich');
  const bundlePath = buildAdminAppInstallPath('bundle', 'media');

  assert.equal(appPath, '/admin/apps/install/app/install-immich');
  assert.equal(bundlePath, '/admin/apps/install/bundle/media');
  assert.deepEqual(parseAdminAppInstallPath(appPath), { kind: 'app', id: 'install-immich' });
  assert.deepEqual(parseAdminAppInstallPath(bundlePath), { kind: 'bundle', id: 'media' });
  assert.equal(parseAdminAppInstallPath('/admin/apps'), null);
});

test('bundle install queue skips installed apps and keeps runnable ones', () => {
  const cardsById = new Map([
    ['install-immich', { id: 'install-immich', app_state: 'ready', title: 'Immich' }],
    ['install-nextcloud', { id: 'install-nextcloud', app_state: 'installed', title: 'Nextcloud' }],
    ['install-opencloud', { id: 'install-opencloud', app_state: 'failed', title: 'OpenCloud' }],
    ['install-zulip', { id: 'install-zulip', app_state: 'planned', title: 'Zulip' }],
  ]);

  const queue = buildBundleInstallQueue({
    apps: ['install-immich', 'install-nextcloud', 'install-opencloud', 'install-zulip'],
  }, cardsById);

  assert.deepEqual(queue.map((card) => card.id), ['install-immich', 'install-opencloud']);
  assert.deepEqual(buildBundleInstallSummary(queue), {
    state: 'ready',
    label: '2 apps in this bundle',
  });
});

test('installed apps stay installable for explicit reinstalls', () => {
  const installedCard = { id: 'install-immich', app_state: 'installed', placeholder: false };
  const plannedCard = { id: 'install-zulip', app_state: 'planned', placeholder: false };

  assert.equal(isAdminAppInstallEnabled(installedCard), true);
  assert.equal(isAdminAppInstallEnabled(plannedCard), false);
  assert.deepEqual(getAdminAppInstallButtonState(installedCard), {
    enabled: true,
    label: 'Install',
  });
  assert.deepEqual(getAdminAppInstallButtonState(plannedCard), {
    enabled: false,
    label: 'Unavailable',
  });
});

test('icon resolver keeps explicit artwork and falls back to step icons', () => {
  assert.equal(resolveAdminCardIconUrl({
    id: 'install-immich',
    iconUrl: '/assets/custom/immich.svg',
  }), '/assets/custom/immich.svg');

  assert.equal(resolveAdminCardIconUrl({
    id: 'install-immich',
    icon_artwork_url: '/assets/custom/immich-alt.svg',
  }), '/assets/custom/immich-alt.svg');

  assert.equal(resolveAdminCardIconUrl({
    id: 'install-nextcloud',
    sourceStepId: 'install-nextcloud',
  }), '/assets/step-icons/install-nextcloud.svg');

  assert.equal(resolveAdminCardIconUrl({
    id: 'install-dashy-dashboard',
    title: 'Dashy',
  }), '/assets/step-icons/install-dashy-dashboard.svg');
});
