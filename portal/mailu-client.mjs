import crypto from "crypto";

export function createRandomMailboxPassword() {
  return crypto.randomBytes(24).toString("hex");
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
