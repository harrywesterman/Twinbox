import assert from "node:assert/strict";
import test from "node:test";

import {
  createSourceAllowlistMiddleware,
  isSourceAllowed,
  parseTrustedCidrs,
} from "../src/lib/source-allowlist.js";

test("source allowlist accepts localhost and configured CIDRs", () => {
  const trustedCidrs = parseTrustedCidrs("127.0.0.1/32,::1/128,10.42.0.0/16");

  assert.equal(isSourceAllowed("127.0.0.1", trustedCidrs), true);
  assert.equal(isSourceAllowed("::1", trustedCidrs), true);
  assert.equal(isSourceAllowed("::ffff:127.0.0.1", trustedCidrs), true);
  assert.equal(isSourceAllowed("10.42.3.9", trustedCidrs), true);
});

test("source allowlist defaults include cluster and docker private ranges only", () => {
  const trustedCidrs = parseTrustedCidrs();

  assert.equal(isSourceAllowed("10.244.2.224", trustedCidrs), true);
  assert.equal(isSourceAllowed("172.18.0.1", trustedCidrs), true);
  assert.equal(isSourceAllowed("192.168.2.70", trustedCidrs), false);
});

test("source allowlist rejects addresses outside configured CIDRs", () => {
  const trustedCidrs = parseTrustedCidrs("127.0.0.1/32,10.42.0.0/16");

  assert.equal(isSourceAllowed("10.43.0.1", trustedCidrs), false);
  assert.equal(isSourceAllowed("192.168.1.25", trustedCidrs), false);
  assert.equal(isSourceAllowed("", trustedCidrs), false);
});

test("source allowlist middleware ignores spoofed forwarded headers", () => {
  const trustedCidrs = parseTrustedCidrs("10.42.0.0/16");
  const middleware = createSourceAllowlistMiddleware({ trustedCidrs });
  let nextCalled = false;
  let statusCode = 0;
  let responseBody = null;

  middleware(
    {
      headers: {
        "x-forwarded-for": "10.42.0.8",
      },
      socket: {
        remoteAddress: "203.0.113.10",
      },
    },
    {
      status(code) {
        statusCode = code;
        return this;
      },
      json(body) {
        responseBody = body;
        return this;
      },
    },
    () => {
      nextCalled = true;
    }
  );

  assert.equal(nextCalled, false);
  assert.equal(statusCode, 403);
  assert.deepEqual(responseBody, { error: "manager api source address is not trusted" });
});
