import test from "node:test";
import assert from "node:assert/strict";
import { gatusTestInputs } from "../src/gatus-notifications.js";
import { getWizardSteps } from "../src/journey.js";

test("notification test uses saved channel settings without sending drafts or secrets", () => {
  assert.deepEqual(
    gatusTestInputs({ test_provider: "ntfy", ntfy_token: "private", ntfy_enabled: false }),
    { test_only: true, test_provider: "ntfy" }
  );
  assert.equal(gatusTestInputs({ test_provider: "untrusted" }).test_provider, "telegram");
});

test("Gatus steps follow bastion provisioning and are excluded for other ingress routes", () => {
  const catalog = {
    categories: [
      {
        id: "talos-cluster",
        steps: [
          { id: "provision-netbird-bastion", journey_stage: "setup", ingress_route: "netbird" },
          { id: "install-gatus", journey_stage: "setup", ingress_route: "netbird" },
          { id: "configure-gatus-notifications", journey_stage: "setup", ingress_route: "netbird" },
        ],
      },
    ],
  };
  const netbird = getWizardSteps(catalog, { "choose-ingress-route": { ingress_route: "netbird" } });
  assert.deepEqual(
    netbird.map((step) => step.id),
    ["provision-netbird-bastion", "install-gatus", "configure-gatus-notifications"]
  );
  assert.equal(
    getWizardSteps(catalog, { "choose-ingress-route": { ingress_route: "cloudflare-tunnel" } })
      .length,
    0
  );
});
