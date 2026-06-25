function normalizeOpenAIBaseUrl(baseUrl) {
  const raw = String(baseUrl || "").trim();
  if (!raw) {
    throw new Error("baseUrl is required");
  }
  if (!/^https?:\/\//i.test(raw)) {
    throw new Error("baseUrl must be an absolute http(s) URL");
  }
  const url = new URL(raw);
  if (!["http:", "https:"].includes(url.protocol)) {
    throw new Error("baseUrl must be an absolute http(s) URL");
  }
  return url.toString().replace(/\/+$/, "");
}

async function listModels(provider, apiKey) {
  const baseUrl = normalizeOpenAIBaseUrl(provider.baseUrl);
  if (!baseUrl) {
    throw new Error("provider.baseUrl is required");
  }

  const headers = { "Content-Type": "application/json" };
  if (apiKey) {
    headers["Authorization"] = `Bearer ${apiKey}`;
  }

  const response = await fetch(`${baseUrl}/models`, {
    method: "GET",
    headers,
  });

  if (!response.ok) {
    throw new Error(`listModels failed: ${response.status} ${response.statusText}`);
  }

  return response.json();
}

async function createChatCompletion(provider, apiKey, messages, options = {}) {
  const baseUrl = normalizeOpenAIBaseUrl(provider.baseUrl);
  if (!baseUrl) {
    throw new Error("provider.baseUrl is required");
  }

  const timeoutMs = options.timeoutMs || 60000;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  const headers = { "Content-Type": "application/json" };
  if (apiKey) {
    headers["Authorization"] = `Bearer ${apiKey}`;
  }

  const body = {
    model: provider.model || options.model || "gpt-4o-mini",
    messages,
    ...options.extraBody,
  };

  try {
    const response = await fetch(`${baseUrl}/chat/completions`, {
      method: "POST",
      headers,
      body: JSON.stringify(body),
      signal: controller.signal,
    });

    if (!response.ok) {
      throw new Error(`chat completion failed: ${response.status} ${response.statusText}`);
    }

    return response.json();
  } finally {
    clearTimeout(timer);
  }
}

async function testProvider(provider, apiKey) {
  const baseUrl = normalizeOpenAIBaseUrl(provider.baseUrl);
  if (!baseUrl) {
    return { status: "error", message: "provider.baseUrl is required" };
  }

  const start = Date.now();

  try {
    const modelsResponse = await listModels(provider, apiKey);
    if (!Array.isArray(modelsResponse.data) || modelsResponse.data.length === 0) {
      return {
        status: "error",
        latencyMs: Date.now() - start,
        message: "provider returned no models",
      };
    }
  } catch {
    // optional models call, continue
  }

  try {
    const response = await createChatCompletion(
      provider,
      apiKey,
      [
        {
          role: "system",
          content: "Respond with exactly one word: ok",
        },
        {
          role: "user",
          content: "Say ok",
        },
      ],
      { timeoutMs: 30000 }
    );

    const latencyMs = Date.now() - start;
    const choice = response.choices?.[0];
    const content = choice?.message?.content || "";
    const model = response.model || provider.model || "unknown";

    if (!content) {
      return {
        status: "error",
        latencyMs,
        message: "provider returned empty response",
      };
    }

    return {
      status: "ok",
      latencyMs,
      model,
      message: `Provider responded successfully (${latencyMs}ms, model: ${model})`,
    };
  } catch (err) {
    return {
      status: "error",
      latencyMs: Date.now() - start,
      message: err.message || "unknown error",
    };
  }
}

export { normalizeOpenAIBaseUrl, listModels, createChatCompletion, testProvider };
