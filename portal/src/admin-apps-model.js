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

export function buildAdminAppsViewModel({
  catalog = {},
  query = '',
  selectedAppId = '',
} = {}) {
  const normalizedQuery = normalizeSearchValue(query);
  const category = Array.isArray(catalog?.categories)
    ? catalog.categories.find((entry) => entry.id === 'apps')
    : null;
  const cards = Array.isArray(category?.steps) ? category.steps.map((card) => normalizeAdminCard(card)) : [];
  const filteredCards = cards.filter((card) => matchesQuery(card, normalizedQuery));
  const selectedApp = filteredCards.find((card) => card.id === selectedAppId)
    || cards.find((card) => card.id === selectedAppId)
    || (normalizedQuery ? filteredCards[0] || null : filteredCards[0] || cards[0] || null);
  const bundles = Array.isArray(catalog?.bundles) ? catalog.bundles : [];

  return {
    title: category?.title || 'Apps',
    description: category?.summary || 'Install user-facing applications and collaboration tools.',
    activeCluster: catalog?.active_cluster || null,
    cards,
    filteredCards,
    selectedApp,
    bundles,
    stateCounts: buildStateCounts(cards),
    errors: Array.isArray(catalog?.errors) ? catalog.errors : [],
    hasCards: cards.length > 0,
  };
}
