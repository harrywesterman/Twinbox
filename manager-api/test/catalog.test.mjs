import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

import { buildCatalogResponse } from '../src/lib/catalog.js';

test('catalog prefers the persisted cluster identity over the VM slug when a cluster exists', () => {
  const originalClusterSlug = process.env.TWINBOX_CLUSTER_SLUG;
  process.env.TWINBOX_CLUSTER_SLUG = 'prd';

  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'twinbox-catalog-'));
  const dirs = {
    stepState: path.join(tempRoot, 'step-state'),
    jobs: path.join(tempRoot, 'jobs'),
    clusters: path.join(tempRoot, 'clusters'),
    queue: path.join(tempRoot, 'queue'),
  };

  for (const dir of Object.values(dirs)) {
    fs.mkdirSync(dir, { recursive: true });
  }

  fs.writeFileSync(
    path.join(dirs.clusters, 'cluster.json'),
    JSON.stringify({
      id: 'cluster',
      slug: null,
      status: 'bootstrapped',
      updated_at: '2026-04-10T15:11:34Z',
    }),
  );

  try {
    const catalog = buildCatalogResponse({
      workspaceRoot: process.cwd(),
      dirs,
      clusterId: null,
    });

    const talosCategory = catalog.categories.find((category) => category.id === 'talos-cluster');
    const chooseIngress = talosCategory?.steps.find((step) => step.id === 'choose-ingress-route');
    const provisionNodes = talosCategory?.steps.find((step) => step.id === 'provision-nodes');

    assert.ok(chooseIngress, 'expected choose-ingress-route in the catalog');
    assert.ok(provisionNodes, 'expected provision-nodes in the catalog');
    assert.equal(catalog.cluster_slug, 'cluster');
    assert.deepEqual(
      chooseIngress.inputs.find((input) => input.id === 'ingress_route')?.options.map((option) => option.value),
      ['wiredoor', 'metallb', 'tailscale'],
    );
    assert.equal(
      provisionNodes.inputs.find((input) => input.id === 'name')?.default,
      'cluster',
    );
  } finally {
    if (originalClusterSlug === undefined) {
      delete process.env.TWINBOX_CLUSTER_SLUG;
    } else {
      process.env.TWINBOX_CLUSTER_SLUG = originalClusterSlug;
    }
    fs.rmSync(tempRoot, { recursive: true, force: true });
  }
});

test('catalog falls back to the VM slug before a persisted cluster exists', () => {
  const originalClusterSlug = process.env.TWINBOX_CLUSTER_SLUG;
  process.env.TWINBOX_CLUSTER_SLUG = 'prd';

  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'twinbox-catalog-'));
  const dirs = {
    stepState: path.join(tempRoot, 'step-state'),
    jobs: path.join(tempRoot, 'jobs'),
    clusters: path.join(tempRoot, 'clusters'),
    queue: path.join(tempRoot, 'queue'),
  };

  for (const dir of Object.values(dirs)) {
    fs.mkdirSync(dir, { recursive: true });
  }

  try {
    const catalog = buildCatalogResponse({
      workspaceRoot: process.cwd(),
      dirs,
      clusterId: null,
    });

    const talosCategory = catalog.categories.find((category) => category.id === 'talos-cluster');
    const chooseIngress = talosCategory?.steps.find((step) => step.id === 'choose-ingress-route');
    const provisionNodes = talosCategory?.steps.find((step) => step.id === 'provision-nodes');

    assert.ok(chooseIngress, 'expected choose-ingress-route in the catalog');
    assert.ok(provisionNodes, 'expected provision-nodes in the catalog');
    assert.equal(catalog.cluster_slug, 'prd');
    assert.deepEqual(
      chooseIngress.inputs.find((input) => input.id === 'ingress_route')?.options.map((option) => option.value),
      ['wiredoor', 'cloudflare-tunnel', 'metallb', 'tailscale'],
    );
    assert.equal(
      provisionNodes.inputs.find((input) => input.id === 'name')?.default,
      'prd',
    );
  } finally {
    if (originalClusterSlug === undefined) {
      delete process.env.TWINBOX_CLUSTER_SLUG;
    } else {
      process.env.TWINBOX_CLUSTER_SLUG = originalClusterSlug;
    }
    fs.rmSync(tempRoot, { recursive: true, force: true });
  }
});
