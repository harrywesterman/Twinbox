function trimString(value) {
  return typeof value === 'string' ? value.trim() : '';
}

function normalizeSearchValue(value) {
  return trimString(value).toLowerCase();
}

function isVisibleUser(user) {
  const username = normalizeSearchValue(user?.username);
  const name = normalizeSearchValue(user?.name);
  const type = normalizeSearchValue(user?.type);

  if (type === 'service_account') {
    return false;
  }

  if (username === 'akadmin') {
    return false;
  }

  if (username.startsWith('outpost-') || username.startsWith('ak-outpost-')) {
    return false;
  }

  if (name.includes('default admin')) {
    return false;
  }

  if (name.includes('embedded outpost service-account')) {
    return false;
  }

  return true;
}

export function buildAdminNavigationItems({ isAdmin = false, zoneName = '' } = {}) {
  if (!isAdmin) {
    return [];
  }

  const items = [
    {
      id: 'admin-app-installs',
      path: '/admin/apps',
      label: 'App installs',
    },
    {
      id: 'admin-observability',
      path: '/admin/observability',
      label: 'Observability',
    },
    {
      id: 'admin-users',
      path: '/admin/users',
      label: 'Users & groups',
    },
  ];

  if (zoneName) {
    items.splice(1, 0, {
      id: 'admin-management-consoles',
      url: `https://admin.${zoneName}`,
      label: 'Management consoles',
    });
  }

  return items;
}

export function buildUserAdminViewModel({
  config = {},
  users = [],
  groups = [],
  query = '',
  selectedUserId = '',
} = {}) {
  const userAdminConfig = config?.userAdmin || {};
  const configuredGroups = Array.isArray(userAdminConfig.manageableGroups)
    ? userAdminConfig.manageableGroups
    : [];
  const normalizedQuery = normalizeSearchValue(query);
  const normalizedUsers = Array.isArray(users) ? users : [];
  const normalizedGroups = Array.isArray(groups) ? groups : [];
  const visibleUsers = normalizedUsers.filter((user) => isVisibleUser(user));

  const filteredUsers = visibleUsers.filter((user) => {
    if (!normalizedQuery) {
      return true;
    }

    const haystacks = [
      user?.name,
      user?.username,
      user?.email,
      ...(Array.isArray(user?.groups) ? user.groups.map((group) => group?.label || group?.name) : []),
      ...(Array.isArray(user?.groupNames) ? user.groupNames : []),
    ];

    return haystacks.some((value) => normalizeSearchValue(value).includes(normalizedQuery));
  });

  const selectedUser = filteredUsers.find((user) => user.id === selectedUserId)
    || visibleUsers.find((user) => user.id === selectedUserId)
    || filteredUsers[0]
    || null;

  const selectedGroupNames = new Set(selectedUser?.groupNames || []);
  const groupsWithSelection = normalizedGroups.map((group) => ({
    ...group,
    selected: selectedGroupNames.has(group.name),
  }));

  let emptyState = null;
  if (configuredGroups.length === 0) {
    emptyState = {
      title: userAdminConfig.emptyStateTitle || 'Nog geen beheerbare groepen ingesteld',
      description: userAdminConfig.emptyStateDescription || 'Voeg eerst beheerbare groepen toe aan de portal-config.',
      kind: 'not-configured',
    };
  } else if (normalizedGroups.length === 0) {
    emptyState = {
      title: 'Nog geen beheerbare groepen gevonden',
      description: 'De allowlist is ingesteld, maar deze groepen bestaan nog niet in Authentik of zijn bewust weggefilterd.',
      kind: 'not-found',
    };
  }

  return {
    title: userAdminConfig.title || 'Gebruikers en groepen',
    description: userAdminConfig.description || 'Beheer gebruikers en groepen vanuit het portal.',
    filteredUsers,
    selectedUser,
    groups: groupsWithSelection,
    emptyState,
    stats: {
      totalUsers: visibleUsers.length,
      activeUsers: visibleUsers.filter((user) => user?.isActive).length,
      inactiveUsers: visibleUsers.filter((user) => user?.isActive === false).length,
      manageableGroups: normalizedGroups.length,
    },
  };
}
