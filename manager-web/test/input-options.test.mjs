import test from "node:test";
import assert from "node:assert/strict";

import { getInputOptions } from "../src/input-options.js";

const input = {
  options: [
    { label: "CAX11", value: "cax11" },
    { label: "CPX12", value: "cpx12" },
  ],
};

test("getInputOptions keeps known values unchanged", () => {
  assert.deepEqual(getInputOptions(input, "cpx12"), input.options);
});

test("getInputOptions preserves an unknown saved value", () => {
  assert.deepEqual(getInputOptions(input, "cpx21"), [
    ...input.options,
    { label: "cpx21 (saved value)", value: "cpx21" },
  ]);
});

test("getInputOptions does not add an empty saved value", () => {
  assert.deepEqual(getInputOptions(input, ""), input.options);
});
