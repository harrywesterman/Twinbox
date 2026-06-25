import test from "node:test";
import assert from "node:assert/strict";
import { getKubernetesListItems } from "../src/k8s-list-response.mjs";

test("getKubernetesListItems accepts legacy body-wrapped responses", () => {
  const items = [{ metadata: { name: "wrapped" } }];
  assert.deepEqual(getKubernetesListItems({ body: { items } }), items);
});

test("getKubernetesListItems accepts direct list responses", () => {
  const items = [{ metadata: { name: "direct" } }];
  assert.deepEqual(getKubernetesListItems({ items }), items);
});

test("getKubernetesListItems returns an empty list for missing items", () => {
  assert.deepEqual(getKubernetesListItems(null), []);
  assert.deepEqual(getKubernetesListItems({}), []);
  assert.deepEqual(getKubernetesListItems({ body: {} }), []);
});
