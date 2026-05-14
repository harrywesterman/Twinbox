import test from "node:test";
import assert from "node:assert/strict";

import {
  buildAdminDashboardUrl,
  buildPortalUrl,
  twinboxPublicZoneName,
} from "../src/cluster-public-zone.js";

test("buildPortalUrl prefers the persisted public zone name", () => {
  assert.equal(
    buildPortalUrl({
      public_zone_name: "tst.example.com",
      slug: "tst",
      dns_domain: "ignored.example",
    }),
    "https://portal.tst.example.com"
  );
});

test("buildPortalUrl falls back to the legacy slug plus dns domain projection", () => {
  assert.equal(
    buildPortalUrl({
      slug: "tst",
      dns_domain: "example.com",
    }),
    "https://portal.tst.example.com"
  );
});

test("buildPortalUrl can use fallback wizard context when the cluster record is missing", () => {
  assert.equal(
    buildPortalUrl(
      {},
      {
        slug: "twinbox-demo",
        dns_domain: "example.com",
      }
    ),
    "https://portal.demo.example.com"
  );
});

test("buildPortalUrl can use the DNS step context when the cluster record is missing", () => {
  assert.equal(
    buildPortalUrl(
      {},
      {
        slug: "tst",
        dns_domain: "example.com",
      }
    ),
    "https://portal.tst.example.com"
  );
});

test("buildAdminDashboardUrl remains an alias for buildPortalUrl", () => {
  assert.equal(
    buildAdminDashboardUrl({
      public_zone_name: "tst.example.com",
      slug: "tst",
      dns_domain: "ignored.example",
    }),
    "https://portal.tst.example.com"
  );
});

test("twinboxPublicZoneName keeps the prd cluster on the base domain", () => {
  assert.equal(twinboxPublicZoneName("prd", "example.com"), "example.com");
});

test("buildAdminDashboardUrl returns an empty string when no zone can be built", () => {
  assert.equal(buildAdminDashboardUrl({}), "");
  assert.equal(buildAdminDashboardUrl({ slug: "tst", dns_domain: "" }), "");
  assert.equal(twinboxPublicZoneName("", "example.com"), "");
});
