import test from "node:test";
import assert from "node:assert/strict";
import { normalizeOpenAIBaseUrl } from "../src/llm-client.mjs";

test("normalizeOpenAIBaseUrl handles http", () => {
  assert.equal(normalizeOpenAIBaseUrl("http://localhost:8080/v1"), "http://localhost:8080/v1");
});

test("normalizeOpenAIBaseUrl handles https", () => {
  assert.equal(normalizeOpenAIBaseUrl("https://ai.example.com/v1"), "https://ai.example.com/v1");
});

test("normalizeOpenAIBaseUrl trims trailing slash", () => {
  assert.equal(normalizeOpenAIBaseUrl("https://ai.example.com/v1/"), "https://ai.example.com/v1");
  assert.equal(normalizeOpenAIBaseUrl("https://ai.example.com/"), "https://ai.example.com");
});

test("normalizeOpenAIBaseUrl rejects invalid protocols", () => {
  assert.throws(() => normalizeOpenAIBaseUrl("ftp://localhost"), /http/);
  assert.throws(() => normalizeOpenAIBaseUrl("file:///path"), /http/);
});

test("normalizeOpenAIBaseUrl rejects relative URLs", () => {
  assert.throws(() => normalizeOpenAIBaseUrl("/v1"), /absolute/);
  assert.throws(() => normalizeOpenAIBaseUrl("localhost:8080"), /absolute/);
});

test("normalizeOpenAIBaseUrl rejects empty string", () => {
  assert.throws(() => normalizeOpenAIBaseUrl(""), /required/);
  assert.throws(() => normalizeOpenAIBaseUrl("   "), /required/);
});
