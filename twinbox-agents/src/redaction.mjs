function redactSensitiveText(value) {
  if (typeof value !== "string") {
    return value;
  }

  let result = value;

  result = result.replace(/(token\s*=)\s*\S+/gi, "$1 TOKEN_REDACTED");
  result = result.replace(/(api_key\s*=)\s*\S+/gi, "$1 API_KEY_REDACTED");
  result = result.replace(/(password\s*=)\s*\S+/gi, "$1 PASSWORD_REDACTED");
  result = result.replace(/(authorization:\s*bearer\s+)\S+/gi, "$1AUTHORIZATION_REDACTED");
  result = result.replace(
    /-----BEGIN\s+PRIVATE\s+KEY-----[\s\S]*?-----END\s+PRIVATE\s+KEY-----/gi,
    "-----BEGIN PRIVATE KEY----- PRIVATE_KEY_REDACTED -----END PRIVATE KEY-----"
  );
  result = result.replace(
    /-----BEGIN\s+RSA\s+PRIVATE\s+KEY-----[\s\S]*?-----END\s+RSA\s+PRIVATE\s+KEY-----/gi,
    "-----BEGIN RSA PRIVATE KEY----- PRIVATE_KEY_REDACTED -----END RSA PRIVATE KEY-----"
  );
  result = result.replace(/(client-key-data:\s*).+/gi, "$1 KUBECONFIG_KEY_REDACTED");

  return result;
}

function redactObject(value) {
  if (typeof value === "string") {
    return redactSensitiveText(value);
  }
  if (Array.isArray(value)) {
    return value.map(redactObject);
  }
  if (value !== null && typeof value === "object") {
    const result = {};
    for (const [key, val] of Object.entries(value)) {
      result[key] = redactObject(val);
    }
    return result;
  }
  return value;
}

export { redactSensitiveText, redactObject };
