import assert from "node:assert/strict";
import test from "node:test";
import { assessmentLabel, securityHeadline } from "../src/admin-security-model.js";

test("security labels distinguish uncertainty from confirmed action", () => {
  assert.equal(securityHeadline({ status: "insufficient_data" }), "Onvoldoende actuele gegevens");
  assert.equal(securityHeadline({ status: "review_needed" }), "Beoordeling nodig");
  assert.equal(assessmentLabel("needs_review"), "te beoordelen");
  assert.equal(assessmentLabel("not_affected"), "onderbouwd niet van toepassing");
});
