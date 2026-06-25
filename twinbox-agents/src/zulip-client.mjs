import { redactSensitiveText } from "./redaction.mjs";

function isZulipConfigured() {
  return !!(
    process.env.ZULIP_BASE_URL &&
    process.env.ZULIP_BOT_EMAIL &&
    process.env.ZULIP_BOT_API_KEY
  );
}

function getStream() {
  return process.env.ZULIP_STREAM || "Twinbox AI";
}

async function postCoordinatorMessage({ topic, content }) {
  if (!isZulipConfigured()) {
    return { skipped: true };
  }

  const baseUrl = process.env.ZULIP_BASE_URL.replace(/\/+$/, "");
  const email = process.env.ZULIP_BOT_EMAIL;
  const apiKey = process.env.ZULIP_BOT_API_KEY;

  const safeContent = redactSensitiveText(content || "").slice(0, 4000);

  const params = new URLSearchParams({
    type: "stream",
    to: getStream(),
    topic: (topic || "AI Report").slice(0, 60),
    content: safeContent,
  });

  const auth = Buffer.from(`${email}:${apiKey}`).toString("base64");

  const response = await fetch(`${baseUrl}/api/v1/messages`, {
    method: "POST",
    headers: {
      Authorization: `Basic ${auth}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: params.toString(),
  });

  if (!response.ok) {
    const body = await response.text();
    throw new Error(`Zulip API error: ${response.status} ${response.statusText} — ${body}`);
  }

  return response.json();
}

export { isZulipConfigured, postCoordinatorMessage };
