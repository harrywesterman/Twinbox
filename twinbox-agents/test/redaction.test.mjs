import test from "node:test";
import assert from "node:assert/strict";
import { redactSensitiveText, redactObject } from "../src/redaction.mjs";

test("redactSensitiveText redacts token=", () => {
  const result = redactSensitiveText("token=abc123def456");
  assert.ok(result.includes("TOKEN_REDACTED"));
  assert.ok(!result.includes("abc123def456"));
});

test("redactSensitiveText redacts api_key", () => {
  const result = redactSensitiveText("api_key=sk-secret-123");
  assert.ok(result.includes("API_KEY_REDACTED"));
});

test("redactSensitiveText redacts password", () => {
  const result = redactSensitiveText("password=supersecret");
  assert.ok(result.includes("PASSWORD_REDACTED"));
});

test("redactSensitiveText redacts Authorization Bearer", () => {
  const result = redactSensitiveText("authorization: bearer eyJhbGciOiJIUzI1NiJ9");
  assert.ok(result.includes("AUTHORIZATION_REDACTED"));
});

test("redactSensitiveText redacts PEM private keys", () => {
  const pem =
    "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQ\n-----END PRIVATE KEY-----";
  const result = redactSensitiveText(pem);
  assert.ok(result.includes("PRIVATE_KEY_REDACTED"));
});

test("redactSensitiveText redacts RSA private keys", () => {
  const pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA\n-----END RSA PRIVATE KEY-----";
  const result = redactSensitiveText(pem);
  assert.ok(result.includes("PRIVATE_KEY_REDACTED"));
});

test("redactSensitiveText returns non-sensitive text unchanged", () => {
  const text = "This is a normal log message without secrets";
  assert.equal(redactSensitiveText(text), text);
});

test("redactObject recursively redacts strings", () => {
  const obj = {
    message: "token=secret123",
    nested: {
      key: "password=admin123",
      safe: "hello",
      arr: ["token=foo", "safe"],
    },
    numbers: [1, 2, 3],
    nullVal: null,
  };

  const result = redactObject(obj);
  assert.ok(result.message.includes("TOKEN_REDACTED"));
  assert.ok(result.nested.key.includes("PASSWORD_REDACTED"));
  assert.equal(result.nested.safe, "hello");
  assert.ok(result.nested.arr[0].includes("TOKEN_REDACTED"));
  assert.equal(result.nested.arr[1], "safe");
  assert.deepEqual(result.numbers, [1, 2, 3]);
  assert.equal(result.nullVal, null);
});
