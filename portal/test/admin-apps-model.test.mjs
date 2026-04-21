import test from 'node:test';
import assert from 'node:assert/strict';

import { buildAdminAppsViewModel } from '../src/admin-apps-model.js';

test('admin app catalog view model enriches bundles with member cards', () => {
  const viewModel = buildAdminAppsViewModel({
    catalog: {
      active_cluster: { id: 'cluster-1', slug: 'tst' },
      errors: [],
      categories: [
        {
          id: 'apps',
          title: 'Apps',
          summary: 'Install user-facing applications and collaboration tools.',
          steps: [
            {
              id: 'install-immich',
              title: 'Install Immich',
              summary: 'Photo app',
              app_state: 'ready',
              placeholder: false,
              order: 10,
              iconText: 'IM',
            },
            {
              id: 'install-nextcloud',
              title: 'Install Nextcloud',
              summary: 'Files app',
              app_state: 'installed',
              placeholder: false,
              order: 20,
              iconText: 'NC',
            },
          ],
        },
      ],
      bundles: [
        {
          id: 'media',
          title: 'Media',
          summary: 'Photo and video tools',
          order: 10,
          apps: ['install-immich', 'install-nextcloud'],
        },
      ],
    },
    query: 'media',
  });

  assert.equal(viewModel.filteredBundles.length, 1);
  assert.equal(viewModel.filteredBundles[0].id, 'media');
  assert.equal(viewModel.filteredBundles[0].cards.length, 2);
  assert.equal(viewModel.filteredBundles[0].status, 'ready');
  assert.equal(viewModel.filteredBundles[0].installedCount, 1);
  assert.equal(viewModel.filteredBundles[0].searchText.includes('photo and video tools'), true);
  assert.equal(viewModel.selectedApp, null);
});
