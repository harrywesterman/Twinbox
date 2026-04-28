function trimString(value) {
  return typeof value === 'string' ? value.trim() : '';
}

function normalizeSearchValue(value) {
  return trimString(value).toLowerCase();
}

function matchesQuery(card, query) {
  if (!query) {
    return true;
  }

  const haystacks = [
    card.title,
    card.summary,
    card.description,
    card.app_state,
    ...(Array.isArray(card.dependencies) ? card.dependencies.map((dependency) => dependency.title || dependency.id) : []),
  ];

  return haystacks.some((value) => normalizeSearchValue(value).includes(query));
}

function buildStateCounts(cards) {
  return cards.reduce((acc, card) => {
    const key = card.app_state || card.status || 'planned';
    acc[key] = (acc[key] || 0) + 1;
    return acc;
  }, {
    planned: 0,
    blocked: 0,
    ready: 0,
    installing: 0,
    installed: 0,
    failed: 0,
  });
}

function normalizeAdminCard(card = {}) {
  return {
    ...card,
    iconUrl: card.iconUrl || card.iconArtworkUrl || card.icon_artwork_url || '',
    iconAlt: card.iconAlt || `${card.title || 'App'} icon`,
  };
}

function compareCardsByTitle(left, right) {
  return String(left?.title || '').localeCompare(String(right?.title || ''), undefined, {
    numeric: true,
    sensitivity: 'base',
  }) || String(left?.id || '').localeCompare(String(right?.id || ''));
}

function normalizeBundleCard(bundle = {}, cardsById = new Map()) {
  const bundleCards = Array.isArray(bundle.apps)
    ? bundle.apps
        .map((appId) => cardsById.get(String(appId)))
        .filter(Boolean)
    : [];

  const installedCount = bundleCards.filter((card) => card.app_state === 'installed').length;
  const installingCount = bundleCards.filter((card) => card.app_state === 'installing').length;
  const readyCount = bundleCards.filter((card) => card.app_state === 'ready').length;
  const blockedCount = bundleCards.filter((card) => card.app_state === 'blocked' || card.app_state === 'planned').length;
  const sourceCard = bundleCards.find((card) => card.iconUrl || card.iconArtworkUrl) || bundleCards[0] || null;
  const status = installingCount > 0
    ? 'installing'
    : blockedCount > 0
      ? 'blocked'
      : installedCount === bundleCards.length && bundleCards.length > 0
        ? 'installed'
        : readyCount > 0
          ? 'ready'
          : 'planned';

  return {
    ...bundle,
    apps: Array.isArray(bundle.apps) ? bundle.apps.map((appId) => String(appId)) : [],
    cards: bundleCards,
    iconUrl: sourceCard?.iconUrl || sourceCard?.iconArtworkUrl || '',
    iconAlt: `${bundle.title || 'Bundle'} icon`,
    iconText: bundleCards[0]?.iconText || bundleCards[0]?.title?.slice(0, 2).toUpperCase() || String(bundle.title || 'GB').slice(0, 2).toUpperCase(),
    status,
    app_state: status,
    installedCount,
    installingCount,
    readyCount,
    blockedCount,
    searchText: [
      bundle.title,
      bundle.summary,
      ...bundleCards.map((card) => card.title),
    ].join(' ').toLowerCase(),
  };
}

function matchesBundleQuery(bundle, query) {
  if (!query) {
    return true;
  }

  return String(bundle.searchText || '').includes(query);
}

export function buildAdminAppsViewModel({
  catalog = {},
  query = '',
  selectedAppId = '',
} = {}) {
  const normalizedQuery = normalizeSearchValue(query);
  const category = Array.isArray(catalog?.categories)
    ? catalog.categories.find((entry) => entry.id === 'apps')
    : null;
  const cards = Array.isArray(category?.steps)
    ? category.steps.map((card) => normalizeAdminCard(card)).sort(compareCardsByTitle)
    : [];
  const cardsById = new Map(cards.map((card) => [card.id, card]));
  const bundles = Array.isArray(catalog?.bundles) ? catalog.bundles.map((bundle) => normalizeBundleCard(bundle, cardsById)) : [];
  const filteredCards = cards.filter((card) => matchesQuery(card, normalizedQuery)).sort(compareCardsByTitle);
  const filteredBundles = bundles.filter((bundle) => matchesBundleQuery(bundle, normalizedQuery));
  const selectedApp = filteredCards.find((card) => card.id === selectedAppId)
    || cards.find((card) => card.id === selectedAppId)
    || (normalizedQuery ? filteredCards[0] || null : filteredCards[0] || cards[0] || null);

  return {
    title: category?.title || 'Apps',
    description: category?.summary || 'Install user-facing applications and collaboration tools.',
    activeCluster: catalog?.active_cluster || null,
    cards,
    filteredCards,
    filteredBundles,
    selectedApp,
    bundles,
    stateCounts: buildStateCounts(cards),
    errors: Array.isArray(catalog?.errors) ? catalog.errors : [],
    hasCards: cards.length > 0,
  };
}
