function trimString(value) {
  return typeof value === 'string' ? value.trim() : '';
}

export function buildAdminAppInstallPath(kind, id) {
  const normalizedKind = trimString(kind);
  const normalizedId = encodeURIComponent(trimString(id));

  if (!normalizedKind || !normalizedId) {
    return '/admin/apps';
  }

  return `/admin/apps/install/${normalizedKind}/${normalizedId}`;
}

export function parseAdminAppInstallPath(pathname = '') {
  const parts = String(pathname || '')
    .split('/')
    .filter(Boolean);

  if (parts.length !== 5 || parts[0] !== 'admin' || parts[1] !== 'apps' || parts[2] !== 'install') {
    return null;
  }

  const kind = trimString(parts[3]) ? parts[3] : '';
  const id = parts[4] ? decodeURIComponent(parts[4]) : '';

  if (!kind || !id) {
    return null;
  }

  if (!['app', 'bundle'].includes(kind)) {
    return null;
  }

  return {
    kind,
    id,
  };
}

export function getInstallableBundleCards(bundle = {}, cardsById = new Map()) {
  const apps = Array.isArray(bundle.apps) ? bundle.apps : [];
  return apps
    .map((appRef) => {
      const appId = typeof appRef === 'string' ? appRef : appRef?.id;
      return appId ? cardsById.get(appId) : null;
    })
    .filter(Boolean);
}

export function buildBundleInstallSummary(bundleCards = []) {
  const cards = Array.isArray(bundleCards) ? bundleCards : [];
  const installed = cards.filter((card) => card?.app_state === 'installed').length;
  const installing = cards.filter((card) => card?.app_state === 'installing').length;
  const blocked = cards.filter((card) => card?.app_state === 'blocked' || card?.app_state === 'planned').length;

  if (installing > 0) {
    return {
      state: 'installing',
      label: `${installing} app${installing === 1 ? '' : 's'} ${installing === 1 ? 'is' : 'are'} currently installing`,
    };
  }

  if (blocked > 0) {
    return {
      state: 'blocked',
      label: `${blocked} app${blocked === 1 ? '' : 's'} still need earlier steps`,
    };
  }

  if (installed === cards.length && cards.length > 0) {
    return {
      state: 'installed',
      label: 'All apps in this bundle are already installed',
    };
  }

  return {
    state: 'ready',
    label: `${cards.length} app${cards.length === 1 ? '' : 's'} in this bundle`,
  };
}

export function buildBundleInstallQueue(bundle = {}, cardsById = new Map()) {
  const bundleCards = getInstallableBundleCards(bundle, cardsById);
  return bundleCards.filter((card) => ['ready', 'failed'].includes(card?.app_state));
}
