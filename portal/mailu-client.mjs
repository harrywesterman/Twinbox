import crypto from "crypto";

export function createRandomMailboxPassword() {
  return crypto.randomBytes(24).toString("hex");
}

export function normalizeMailuTokenRecord(record = {}) {
  return {
    id: String(record.id ?? record.pk ?? "").trim(),
    email: String(record.email ?? record.user_email ?? "").trim(),
    comment: String(record.comment ?? "").trim(),
    authorizedIp: Array.isArray(record.AuthorizedIP) ? record.AuthorizedIP : [],
    createdAt: String(record.Created ?? record.created_at ?? "").trim(),
    updatedAt: String(record["Last edit"] ?? record.updated_at ?? "").trim(),
  };
}

export function resolveMailuApiConfig() {
  const explicitBaseUrl = String(process.env.MAILU_API_BASE_URL || "").trim();
  const token = String(process.env.MAILU_API_TOKEN || "").trim();

  let baseUrl = explicitBaseUrl;
  if (!baseUrl) {
    const portalBaseUrl = String(process.env.PORTAL_BASE_URL || "").trim();
    if (portalBaseUrl) {
      const zone = portalBaseUrl.replace(/^https?:\/\/portal\./, "");
      baseUrl = `https://mail.${zone}/api`;
    }
  }

  return {
    baseUrl: (baseUrl || "").replace(/\/+$/, "") + "/v1",
    token,
  };
}

export function isMailuInstalled() {
  return Boolean(String(process.env.MAILU_API_TOKEN || "").trim());
}

export async function mailuCreateMailbox({ email, rawPassword, displayedName, enabled }) {
  const { baseUrl, token } = resolveMailuApiConfig();
  if (!token) {
    return { ok: false, reason: "no-api-token" };
  }

  const body = JSON.stringify({
    email,
    raw_password: rawPassword,
    displayed_name: displayedName || email.split("@")[0],
    enabled: enabled !== false,
    enable_imap: true,
    enable_pop: false,
    spam_enabled: true,
  });

  try {
    const response = await fetch(`${baseUrl}/user`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${token}`,
      },
      body,
    });

    if (response.status === 409) {
      return { ok: false, reason: "already-exists" };
    }
    if (!response.ok) {
      const errorBody = await response.text().catch(() => "");
      return { ok: false, reason: `http-${response.status}`, detail: errorBody };
    }
    return { ok: true };
  } catch (error) {
    return { ok: false, reason: "network-error", detail: error.message };
  }
}

export async function mailuCheckMailboxExists(email) {
  const { baseUrl, token } = resolveMailuApiConfig();
  if (!token) return false;

  try {
    const response = await fetch(`${baseUrl}/user/${encodeURIComponent(email)}`, {
      method: "GET",
      headers: { Authorization: `Bearer ${token}` },
    });
    return response.status === 200;
  } catch {
    return false;
  }
}

export async function mailuListUserTokens(email) {
  const { baseUrl, token } = resolveMailuApiConfig();
  if (!token) {
    return { ok: false, reason: "no-api-token", tokens: [] };
  }

  try {
    const response = await fetch(`${baseUrl}/tokenuser/${encodeURIComponent(email)}`, {
      method: "GET",
      headers: { Authorization: `Bearer ${token}` },
    });
    if (response.status === 404) {
      return { ok: true, tokens: [] };
    }
    if (!response.ok) {
      const errorBody = await response.text().catch(() => "");
      return { ok: false, reason: `http-${response.status}`, detail: errorBody, tokens: [] };
    }
    const payload = await response.json();
    return {
      ok: true,
      tokens: (Array.isArray(payload) ? payload : []).map(normalizeMailuTokenRecord),
    };
  } catch (error) {
    return { ok: false, reason: "network-error", detail: error.message, tokens: [] };
  }
}

export async function mailuCreateUserToken({ email, comment, authorizedIp = [] }) {
  const { baseUrl, token } = resolveMailuApiConfig();
  if (!token) {
    return { ok: false, reason: "no-api-token" };
  }

  const body = JSON.stringify({
    comment: String(comment || "Mail client").trim(),
    AuthorizedIP: Array.isArray(authorizedIp) ? authorizedIp : [],
  });

  try {
    const response = await fetch(`${baseUrl}/tokenuser/${encodeURIComponent(email)}`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${token}`,
      },
      body,
    });
    if (!response.ok) {
      const errorBody = await response.text().catch(() => "");
      return { ok: false, reason: `http-${response.status}`, detail: errorBody };
    }
    const payload = await response.json();
    return {
      ok: true,
      token: String(payload.token || "").trim(),
      record: normalizeMailuTokenRecord(payload),
    };
  } catch (error) {
    return { ok: false, reason: "network-error", detail: error.message };
  }
}

export async function mailuDeleteUserToken({ email, tokenId, protectedComments = [] }) {
  const { baseUrl, token } = resolveMailuApiConfig();
  if (!token) {
    return { ok: false, reason: "no-api-token" };
  }

  const tokensResult = await mailuListUserTokens(email);
  if (!tokensResult.ok) {
    return tokensResult;
  }
  const requestedId = String(tokenId || "").trim();
  const tokenRecord = tokensResult.tokens.find((entry) => entry.id === requestedId);
  if (!tokenRecord) {
    return { ok: false, reason: "not-found" };
  }
  const protectedCommentSet = new Set(
    (Array.isArray(protectedComments) ? protectedComments : [])
      .map((value) => String(value || "").trim())
      .filter(Boolean)
  );
  if (protectedCommentSet.has(tokenRecord.comment)) {
    return { ok: false, reason: "protected-token" };
  }

  try {
    const response = await fetch(`${baseUrl}/token/${encodeURIComponent(requestedId)}`, {
      method: "DELETE",
      headers: { Authorization: `Bearer ${token}` },
    });
    if (!response.ok) {
      const errorBody = await response.text().catch(() => "");
      return { ok: false, reason: `http-${response.status}`, detail: errorBody };
    }
    return { ok: true };
  } catch (error) {
    return { ok: false, reason: "network-error", detail: error.message };
  }
}
