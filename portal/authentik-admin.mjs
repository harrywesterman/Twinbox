import crypto from "crypto";

export const DEFAULT_AUTHENTIK_API_BASE =
  "http://authentik-server.authentik.svc.cluster.local/api/v3";

const TEMP_PASSWORD_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";

function trimString(value) {
  return typeof value === "string" ? value.trim() : "";
}

function normalizeId(value) {
  if (value === undefined || value === null) {
    return "";
  }
  return String(value).trim();
}

function normalizeLabel(value, fallback) {
  return trimString(value) || fallback;
}

export function normalizeManageableGroupsConfig(value) {
  if (!Array.isArray(value)) {
    return [];
  }

  return value
    .map((entry) => {
      if (typeof entry === "string") {
        const name = trimString(entry);
        if (!name) {
          return null;
        }
        return {
          name,
          label: name,
          description: "",
        };
      }

      if (!entry || typeof entry !== "object") {
        return null;
      }

      const name = trimString(entry.name);
      if (!name) {
        return null;
      }

      return {
        name,
        label: normalizeLabel(entry.label, name),
        description: trimString(entry.description),
      };
    })
    .filter(Boolean);
}

export function isServiceAccountUser(user = {}) {
  const type = trimString(user.type).toLowerCase();
  return type === "service_account";
}

export function blockedGroupReason(group = {}) {
  const name = trimString(group.name);
  const normalizedName = name.toLowerCase();

  if (group?.is_superuser === true) {
    return "superuser";
  }

  if (normalizedName === "admins") {
    return "admins";
  }

  if (/^twinbox-automation(?:-|$)/i.test(name)) {
    return "automation";
  }

  if (/service[- ]account/i.test(name)) {
    return "service-account";
  }

  return "";
}

export function filterManageableGroups(groups = [], manageableGroupsConfig = []) {
  const allowedByName = new Map(
    normalizeManageableGroupsConfig(manageableGroupsConfig).map((entry) => [entry.name, entry])
  );

  return groups
    .filter((group) => allowedByName.has(trimString(group?.name)))
    .filter((group) => !blockedGroupReason(group))
    .map((group) => {
      const allowed = allowedByName.get(trimString(group.name));
      const id = normalizeId(group.pk || group.id || group.uuid);
      return {
        id,
        name: trimString(group.name),
        label: normalizeLabel(allowed?.label, trimString(group.name)),
        description: trimString(allowed?.description),
        isSuperuser: group?.is_superuser === true,
      };
    })
    .filter((group) => group.id && group.name)
    .sort((left, right) => left.label.localeCompare(right.label));
}

export function parseGroupUserIds(group = {}) {
  if (Array.isArray(group.users)) {
    return group.users.map((value) => normalizeId(value)).filter(Boolean);
  }

  if (Array.isArray(group.users_obj)) {
    return group.users_obj
      .map((entry) => normalizeId(entry?.pk || entry?.id || entry?.uuid))
      .filter(Boolean);
  }

  return [];
}

export function normalizeRequestedGroupNames(groupNames = []) {
  return [
    ...new Set(
      (Array.isArray(groupNames) ? groupNames : [])
        .map((value) => trimString(value))
        .filter(Boolean)
    ),
  ].sort((left, right) => left.localeCompare(right));
}

export function createTemporaryPassword() {
  const bytes = crypto.randomBytes(16);
  const segments = [];

  for (let segmentIndex = 0; segmentIndex < 4; segmentIndex += 1) {
    let segment = "";
    for (let charIndex = 0; charIndex < 4; charIndex += 1) {
      const byteIndex = segmentIndex * 4 + charIndex;
      const alphabetIndex = bytes[byteIndex] % TEMP_PASSWORD_ALPHABET.length;
      segment += TEMP_PASSWORD_ALPHABET[alphabetIndex];
    }
    segments.push(segment);
  }

  return `Tbx-${segments.join("-")}`;
}

export function buildDirectory({ users = [], groups = [], manageableGroupsConfig = [] }) {
  const manageableGroups = filterManageableGroups(groups, manageableGroupsConfig);
  const manageableGroupsById = new Map(manageableGroups.map((group) => [group.id, group]));
  const membershipsByUserId = new Map();
  const hiddenMembershipCounts = new Map();

  for (const group of groups) {
    const groupId = normalizeId(group.pk || group.id || group.uuid);
    const userIds = parseGroupUserIds(group);
    const manageableGroup = manageableGroupsById.get(groupId);
    const groupName = trimString(group.name);

    for (const userId of userIds) {
      if (manageableGroup) {
        const current = membershipsByUserId.get(userId) || [];
        current.push({
          id: manageableGroup.id,
          name: manageableGroup.name,
          label: manageableGroup.label,
        });
        membershipsByUserId.set(userId, current);
      } else if (groupName && !blockedGroupReason(group)) {
        hiddenMembershipCounts.set(userId, (hiddenMembershipCounts.get(userId) || 0) + 1);
      } else if (groupName) {
        hiddenMembershipCounts.set(userId, (hiddenMembershipCounts.get(userId) || 0) + 1);
      }
    }
  }

  const portalUsers = users
    .filter((user) => !isServiceAccountUser(user))
    .map((user) => {
      const id = normalizeId(user.pk || user.id || user.uuid);
      const memberships = (membershipsByUserId.get(id) || []).sort((left, right) =>
        left.label.localeCompare(right.label)
      );
      return {
        id,
        username: trimString(user.username),
        name: trimString(user.name) || trimString(user.username) || "Unnamed user",
        email: trimString(user.email),
        isActive: user?.is_active !== false,
        groupNames: memberships.map((membership) => membership.name),
        groups: memberships,
        hiddenGroupCount: hiddenMembershipCounts.get(id) || 0,
      };
    })
    .filter((user) => user.id && user.username)
    .sort((left, right) => {
      if (left.isActive !== right.isActive) {
        return left.isActive ? -1 : 1;
      }
      return left.name.localeCompare(right.name);
    });

  return {
    users: portalUsers,
    groups: manageableGroups.map((group) => ({
      ...group,
      memberCount: portalUsers.filter((user) => user.groupNames.includes(group.name)).length,
    })),
  };
}

export function ensureRequestedGroupsAreManageable(
  requestedGroupNames = [],
  manageableGroups = []
) {
  const allowedNames = new Set(manageableGroups.map((group) => group.name));

  for (const groupName of normalizeRequestedGroupNames(requestedGroupNames)) {
    if (!allowedNames.has(groupName)) {
      const error = new Error(`group is not allowed for portal management: ${groupName}`);
      error.status = 400;
      throw error;
    }
  }
}

export function createAuthentikAdminClient({
  baseUrl = DEFAULT_AUTHENTIK_API_BASE,
  token = "",
  fetchImpl = globalThis.fetch,
} = {}) {
  const normalizedBaseUrl = trimString(baseUrl).replace(/\/+$/, "");
  const normalizedToken = trimString(token);

  if (!normalizedBaseUrl) {
    throw new Error("AUTHENTIK_API_BASE is not configured");
  }

  if (!normalizedToken) {
    throw new Error("AUTHENTIK_API_TOKEN is not configured");
  }

  if (typeof fetchImpl !== "function") {
    throw new Error("fetch implementation is required");
  }

  async function request(method, pathname, { body } = {}) {
    const response = await fetchImpl(`${normalizedBaseUrl}${pathname}`, {
      method,
      headers: {
        Accept: "application/json",
        Authorization: `Bearer ${normalizedToken}`,
        ...(body ? { "Content-Type": "application/json" } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });

    if (response.status === 204) {
      return null;
    }

    const text = await response.text();
    let payload = null;

    if (text) {
      try {
        payload = JSON.parse(text);
      } catch {
        payload = text;
      }
    }

    if (!response.ok) {
      const error = new Error(
        payload?.detail ||
          payload?.error ||
          payload?.message ||
          text ||
          `Authentik API ${method} ${pathname} failed with HTTP ${response.status}`
      );
      error.status = response.status;
      throw error;
    }

    return payload;
  }

  return {
    listUsers() {
      return request("GET", "/core/users/?page_size=200");
    },
    getUser(userId) {
      return request("GET", `/core/users/${encodeURIComponent(userId)}/`);
    },
    createUser(payload) {
      return request("POST", "/core/users/", { body: payload });
    },
    updateUser(userId, payload) {
      return request("PATCH", `/core/users/${encodeURIComponent(userId)}/`, { body: payload });
    },
    setPassword(userId, password) {
      return request("POST", `/core/users/${encodeURIComponent(userId)}/set_password/`, {
        body: { password },
      });
    },
    listGroups() {
      return request("GET", "/core/groups/?page_size=200");
    },
    getGroup(groupId) {
      return request("GET", `/core/groups/${encodeURIComponent(groupId)}/`);
    },
    addUserToGroup(groupId, userId) {
      return request("POST", `/core/groups/${encodeURIComponent(groupId)}/add_user/`, {
        body: { pk: userId },
      });
    },
    removeUserFromGroup(groupId, userId) {
      return request("POST", `/core/groups/${encodeURIComponent(groupId)}/remove_user/`, {
        body: { pk: userId },
      });
    },
    listWebAuthnDevices(userId) {
      return request(
        "GET",
        `/authenticators/admin/webauthn/?page_size=200&user=${encodeURIComponent(userId)}`
      );
    },
    deleteWebAuthnDevice(deviceId) {
      return request("DELETE", `/authenticators/admin/webauthn/${encodeURIComponent(deviceId)}/`);
    },
  };
}
