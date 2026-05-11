import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";

import { buildAppCatalogResponse } from "../src/lib/catalog.js";

test("karakeep app catalog exposes the real runner", () => {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "twinbox-karakeep-catalog-"));
  const dirs = {
    stepState: path.join(tempRoot, "step-state"),
    jobs: path.join(tempRoot, "jobs"),
    clusters: path.join(tempRoot, "clusters"),
    queue: path.join(tempRoot, "queue"),
  };

  for (const dir of Object.values(dirs)) {
    fs.mkdirSync(dir, { recursive: true });
  }

  fs.mkdirSync(path.join(dirs.stepState, "clusters", "cluster-1-instance"), { recursive: true });
  fs.writeFileSync(
    path.join(dirs.clusters, "cluster-1.json"),
    JSON.stringify({
      id: "cluster-1",
      slug: "tst",
      dns_domain: "example.com",
      cluster_instance_id: "cluster-1-instance",
      status: "bootstrapped",
      updated_at: "2026-04-10T15:11:34Z",
    })
  );
  fs.writeFileSync(
    path.join(dirs.stepState, "clusters", "cluster-1-instance", "install-karakeep.json"),
    JSON.stringify({
      step_id: "install-karakeep",
      status: "not_started",
      inputs: {},
      outputs: null,
      cluster_id: "cluster-1",
      cluster_instance_id: "cluster-1-instance",
    })
  );

  try {
    const appCatalog = buildAppCatalogResponse({
      workspaceRoot: process.cwd(),
      dirs,
      clusterId: "cluster-1",
    });

    const karakeepCard = appCatalog.categories[0].steps.find(
      (step) => step.id === "install-karakeep"
    );
    assert.equal(karakeepCard?.title, "Install Karakeep");
    assert.equal(karakeepCard?.runner?.script, "categories/apps/steps/install-karakeep/run.sh");
    assert.equal(karakeepCard?.placeholder, false);
  } finally {
    fs.rmSync(tempRoot, { recursive: true, force: true });
  }
});
