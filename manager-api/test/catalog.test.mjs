import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";

import {
  buildAppCatalogResponse,
  buildCatalogResponse,
  partitionStepInputs,
  validateStepInputs,
} from "../src/lib/catalog.js";
import {
  buildClusterWorkerSecretBundle,
  buildSecretAttachmentRef,
  mergeSecretBundles,
} from "../../lib/secrets/schema.mjs";

test("password inputs validate and sensitive values are partitioned out of job inputs", () => {
  const step = {
    inputs: [
      { id: "endpoint", type: "string", required: true },
      {
        id: "secret",
        type: "password",
        required: true,
        sensitive: true,
        secret_field: "secret_access_key",
      },
    ],
  };

  const validated = validateStepInputs(step, {
    endpoint: "https://s3.example.com",
    secret: "do-not-persist",
  });
  assert.equal(validated.ok, true);
  assert.deepEqual(partitionStepInputs(step, validated.value), {
    publicInputs: { endpoint: "https://s3.example.com" },
    secretFields: { secret_access_key: "do-not-persist" },
  });
});

test("conditional backup fields are required only for the selected mode", () => {
  const step = {
    inputs: [
      { id: "mode", type: "string", required: true },
      {
        id: "endpoint",
        type: "string",
        required: true,
        visible_when: { input: "mode", equals: "external" },
      },
      {
        id: "datastore",
        type: "string",
        required: true,
        visible_when: { input: "mode", equals: "managed" },
      },
    ],
  };
  assert.equal(validateStepInputs(step, { mode: "external" }).error, "endpoint is required");
  assert.deepEqual(validateStepInputs(step, { mode: "external", endpoint: "https://s3" }), {
    ok: true,
    value: { mode: "external", endpoint: "https://s3" },
  });
  assert.deepEqual(validateStepInputs(step, { mode: "managed", datastore: "backup" }), {
    ok: true,
    value: { mode: "managed", datastore: "backup" },
  });
});

test("catalog prefers the persisted cluster identity over the VM slug when a cluster exists", () => {
  const originalClusterSlug = process.env.TWINBOX_CLUSTER_SLUG;
  process.env.TWINBOX_CLUSTER_SLUG = "prd";

  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "twinbox-catalog-"));
  const dirs = {
    stepState: path.join(tempRoot, "step-state"),
    jobs: path.join(tempRoot, "jobs"),
    clusters: path.join(tempRoot, "clusters"),
    queue: path.join(tempRoot, "queue"),
  };

  for (const dir of Object.values(dirs)) {
    fs.mkdirSync(dir, { recursive: true });
  }

  fs.writeFileSync(
    path.join(dirs.clusters, "cluster.json"),
    JSON.stringify({
      id: "cluster",
      slug: null,
      status: "bootstrapped",
      updated_at: "2026-04-10T15:11:34Z",
    })
  );

  try {
    const catalog = buildCatalogResponse({
      workspaceRoot: process.cwd(),
      dirs,
      clusterId: null,
    });

    const talosCategory = catalog.categories.find((category) => category.id === "talos-cluster");
    const chooseIngress = talosCategory?.steps.find((step) => step.id === "choose-ingress-route");
    const provisionNodes = talosCategory?.steps.find((step) => step.id === "provision-nodes");

    assert.ok(chooseIngress, "expected choose-ingress-route in the catalog");
    assert.ok(provisionNodes, "expected provision-nodes in the catalog");
    assert.equal(catalog.cluster_slug, "cluster");
    assert.deepEqual(
      chooseIngress.inputs
        .find((input) => input.id === "ingress_route")
        ?.options.map((option) => option.value),
      ["netbird"]
    );
    assert.equal(provisionNodes.inputs.find((input) => input.id === "name")?.default, "cluster");
  } finally {
    if (originalClusterSlug === undefined) {
      delete process.env.TWINBOX_CLUSTER_SLUG;
    } else {
      process.env.TWINBOX_CLUSTER_SLUG = originalClusterSlug;
    }
    fs.rmSync(tempRoot, { recursive: true, force: true });
  }
});

test("catalog falls back to the VM slug before a persisted cluster exists", () => {
  const originalClusterSlug = process.env.TWINBOX_CLUSTER_SLUG;
  process.env.TWINBOX_CLUSTER_SLUG = "prd";

  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "twinbox-catalog-"));
  const dirs = {
    stepState: path.join(tempRoot, "step-state"),
    jobs: path.join(tempRoot, "jobs"),
    clusters: path.join(tempRoot, "clusters"),
    queue: path.join(tempRoot, "queue"),
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

    const talosCategory = catalog.categories.find((category) => category.id === "talos-cluster");
    const chooseIngress = talosCategory?.steps.find((step) => step.id === "choose-ingress-route");
    const provisionNodes = talosCategory?.steps.find((step) => step.id === "provision-nodes");

    assert.ok(chooseIngress, "expected choose-ingress-route in the catalog");
    assert.ok(provisionNodes, "expected provision-nodes in the catalog");
    assert.equal(catalog.cluster_slug, "prd");
    assert.deepEqual(
      chooseIngress.inputs
        .find((input) => input.id === "ingress_route")
        ?.options.map((option) => option.value),
      ["cloudflare-tunnel", "netbird"]
    );
    assert.equal(provisionNodes.inputs.find((input) => input.id === "name")?.default, "prd");
  } finally {
    if (originalClusterSlug === undefined) {
      delete process.env.TWINBOX_CLUSTER_SLUG;
    } else {
      process.env.TWINBOX_CLUSTER_SLUG = originalClusterSlug;
    }
    fs.rmSync(tempRoot, { recursive: true, force: true });
  }
});

test("catalog exposes NetBird bastion without duplicate DNS, SSH, or Cloudflare inputs", () => {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "twinbox-catalog-"));
  const dirs = {
    stepState: path.join(tempRoot, "step-state"),
    jobs: path.join(tempRoot, "jobs"),
    clusters: path.join(tempRoot, "clusters"),
    queue: path.join(tempRoot, "queue"),
  };

  for (const dir of Object.values(dirs)) {
    fs.mkdirSync(dir, { recursive: true });
  }
  fs.writeFileSync(
    path.join(dirs.clusters, "cluster.json"),
    JSON.stringify({
      id: "cluster",
      slug: "tst",
      dns_domain: "example.com",
      selected_ingress_route: "netbird",
      status: "bootstrapped",
      updated_at: "2026-05-18T10:00:00Z",
    })
  );

  try {
    const catalog = buildCatalogResponse({
      workspaceRoot: process.cwd(),
      dirs,
      clusterId: "cluster",
    });

    const talosCategory = catalog.categories.find((category) => category.id === "talos-cluster");
    const netbirdBastion = talosCategory?.steps.find(
      (step) => step.id === "provision-netbird-bastion"
    );
    const createUsers = talosCategory?.steps.find((step) => step.id === "create-users-and-groups");

    assert.ok(netbirdBastion, "expected provision-netbird-bastion in the catalog");
    assert.deepEqual(
      netbirdBastion.inputs.map((input) => input.id),
      [
        "bastion_provider",
        "hcloud_token",
        "hcloud_location",
        "hcloud_server_type",
        "existing_bastion_mode",
        "existing_bastion_public_ipv4",
        "existing_bastion_ssh_host",
        "existing_bastion_ssh_port",
        "existing_bastion_ssh_user",
        "existing_bastion_ssh_private_key",
        "existing_bastion_os_family",
        "existing_bastion_confirm_clean_host",
        "existing_bastion_confirm_port_forwarding",
      ]
    );
    const serverType = netbirdBastion.inputs.find((input) => input.id === "hcloud_server_type");
    assert.equal(serverType.default, "cax11");
    assert.deepEqual(serverType.options, [
      { label: "CAX11 — ARM64, 2 vCPU / 4 GB", value: "cax11" },
      { label: "CPX12 — x86/AMD, 1 vCPU / 2 GB (light/test)", value: "cpx12" },
      { label: "CPX22 — x86/AMD, 2 vCPU / 4 GB", value: "cpx22" },
    ]);
    assert.equal(netbirdBastion.secrets.files.KUBECONFIG_FILE.attachment, "kubeconfig");
    assert.match(netbirdBastion.side_help, /DNS provider configured earlier/);
    assert.doesNotMatch(netbirdBastion.side_help, /Cloudflare credentials/);
    assert.equal(createUsers.inputs.find((input) => input.id === "full_name")?.required, true);
    assert.equal(createUsers.inputs.find((input) => input.id === "username")?.required, true);
    assert.equal(
      createUsers.inputs.find((input) => input.id === "email"),
      undefined
    );
  } finally {
    fs.rmSync(tempRoot, { recursive: true, force: true });
  }
});

test("app catalog exposes apps while the wizard catalog keeps them out of sight", () => {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "twinbox-app-catalog-"));
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
    path.join(dirs.stepState, "clusters", "cluster-1-instance", "install-immich.json"),
    JSON.stringify({
      step_id: "install-immich",
      status: "not_started",
      inputs: {},
      outputs: null,
      cluster_id: "cluster-1",
      cluster_instance_id: "cluster-1-instance",
    })
  );
  for (const dependency of [
    "choose-ingress-route",
    "install-longhorn-storage",
    "install-cloudnativepg",
    "install-secret-sync",
    "install-authentik-idp",
  ]) {
    fs.writeFileSync(
      path.join(dirs.stepState, "clusters", "cluster-1-instance", `${dependency}.json`),
      JSON.stringify({
        step_id: dependency,
        status: "succeeded",
        inputs: {},
        outputs: {},
        cluster_id: "cluster-1",
        cluster_instance_id: "cluster-1-instance",
      })
    );
  }

  try {
    const wizardCatalog = buildCatalogResponse({
      workspaceRoot: process.cwd(),
      dirs,
      clusterId: "cluster-1",
    });
    assert(!wizardCatalog.categories.some((category) => category.id === "apps"));

    const appCatalog = buildAppCatalogResponse({
      workspaceRoot: process.cwd(),
      dirs,
      clusterId: "cluster-1",
    });
    assert.equal(appCatalog.active_cluster.id, "cluster-1");
    assert.equal(appCatalog.categories[0].id, "apps");
    const nextcloudCard = appCatalog.categories[0].steps.find(
      (step) => step.id === "install-nextcloud"
    );
    const immichCard = appCatalog.categories[0].steps.find((step) => step.id === "install-immich");
    const pixelfedCard = appCatalog.categories[0].steps.find(
      (step) => step.id === "install-pixelfed"
    );
    const freshrssCard = appCatalog.categories[0].steps.find(
      (step) => step.id === "install-freshrss"
    );
    const headwindMdmCard = appCatalog.categories[0].steps.find(
      (step) => step.id === "install-headwind-mdm"
    );
    const vaultwardenCard = appCatalog.categories[0].steps.find(
      (step) => step.id === "install-vaultwarden"
    );
    const hedgedocCard = appCatalog.categories[0].steps.find(
      (step) => step.id === "install-hedgedoc"
    );
    const penpotCard = appCatalog.categories[0].steps.find((step) => step.id === "install-penpot");
    const mijnBureauBundle = appCatalog.bundles.find((bundle) => bundle.id === "mijn-bureau");
    const nextcloudBundle = appCatalog.bundles.find((bundle) => bundle.id === "nextcloud");
    const openDeskBundle = appCatalog.bundles.find((bundle) => bundle.id === "opendesk");
    const laSuiteBundle = appCatalog.bundles.find((bundle) => bundle.id === "lasuite");
    const twinboxDesktopBundle = appCatalog.bundles.find(
      (bundle) => bundle.id === "twinbox-desktop"
    );
    for (const appId of [
      "install-karakeep",
      "install-mailu",
      "install-mastodon",
      "install-matrix",
    ]) {
      assert.ok(
        twinboxDesktopBundle?.apps.includes(appId),
        `twinbox-desktop bundle should include ${appId}`
      );
    }
    assert.equal(twinboxDesktopBundle?.apps.includes("install-nextcloud"), false);
    assert.equal(nextcloudCard?.title, "Install Nextcloud");
    assert.equal(nextcloudCard?.placeholder, false);
    assert.equal(nextcloudCard?.installable, true);
    assert.equal(nextcloudCard?.runner?.script, "categories/apps/steps/install-nextcloud/run.sh");
    assert.equal(immichCard?.title, "Install Immich");
    assert.equal(immichCard?.app_state, "ready");
    assert.equal(immichCard?.runner?.script, "categories/apps/steps/install-immich/run.sh");
    assert.equal(pixelfedCard?.title, "Install Pixelfed");
    assert.equal(pixelfedCard?.placeholder, false);
    assert.equal(pixelfedCard?.installable, true);
    assert.equal(pixelfedCard?.runner?.script, "categories/apps/steps/install-pixelfed/run.sh");
    assert.equal(vaultwardenCard?.title, "Install Vaultwarden");
    assert.equal(vaultwardenCard?.placeholder, false);
    assert.equal(vaultwardenCard?.installable, true);
    assert.equal(
      vaultwardenCard?.runner?.script,
      "categories/apps/steps/install-vaultwarden/run.sh"
    );
    assert.equal(hedgedocCard?.title, "Install HedgeDoc");
    assert.equal(hedgedocCard?.placeholder, false);
    assert.equal(hedgedocCard?.installable, true);
    assert.equal(hedgedocCard?.runner?.script, "categories/apps/steps/install-hedgedoc/run.sh");
    assert.equal(penpotCard?.title, "Install Penpot");
    assert.equal(penpotCard?.placeholder, false);
    assert.equal(penpotCard?.installable, true);
    assert.equal(penpotCard?.runner?.script, "categories/apps/steps/install-penpot/run.sh");
    assert.equal(freshrssCard?.title, "Install FreshRSS");
    assert.equal(freshrssCard?.placeholder, false);
    assert.equal(freshrssCard?.installable, true);
    assert.equal(freshrssCard?.app_state, "ready");
    assert.equal(freshrssCard?.runner?.script, "categories/apps/steps/install-freshrss/run.sh");
    assert.equal(headwindMdmCard?.title, "Install Headwind MDM");
    assert.equal(headwindMdmCard?.placeholder, false);
    assert.equal(headwindMdmCard?.installable, true);
    assert.equal(headwindMdmCard?.app_state, "ready");
    assert.equal(
      headwindMdmCard?.runner?.script,
      "categories/apps/steps/install-headwind-mdm/run.sh"
    );
    assert.equal(mijnBureauBundle?.title, "Mijn Bureau");
    assert.equal(mijnBureauBundle?.iconUrl, "/assets/step-icons/install-nextcloud.svg");
    assert.deepEqual(mijnBureauBundle?.apps, [
      "install-nextcloud",
      "install-outline",
      "install-jitsi",
    ]);
    assert.equal(nextcloudBundle?.title, "Nextcloud");
    assert.equal(nextcloudBundle?.iconUrl, "/assets/step-icons/install-nextcloud.svg");
    assert.deepEqual(nextcloudBundle?.apps, ["install-mailu", "install-nextcloud"]);
    assert.equal(openDeskBundle?.title, "openDesk");
    assert.equal(openDeskBundle?.iconUrl, "/assets/step-icons/install-opencloud.svg");
    assert.deepEqual(openDeskBundle?.apps, [
      "install-opencloud",
      "install-nextcloud",
      "install-mailu",
      "install-zulip",
      "install-jitsi",
    ]);
    assert.equal(laSuiteBundle?.title, "La Suite");
    assert.equal(laSuiteBundle?.iconUrl, "/assets/step-icons/install-outline.svg");
    assert.deepEqual(laSuiteBundle?.apps, [
      "install-outline",
      "install-nextcloud",
      "install-mailu",
      "install-zulip",
      "install-matrix",
      "install-jitsi",
    ]);
    for (const bundle of [openDeskBundle, laSuiteBundle, twinboxDesktopBundle]) {
      assert.ok(bundle);
      assert.ok(
        bundle.apps.indexOf("install-mailu") < bundle.apps.indexOf("install-zulip"),
        `${bundle.id} should install Mailu before Zulip`
      );
    }
    assert.ok(nextcloudBundle);
    assert.ok(
      nextcloudBundle.apps.indexOf("install-mailu") <
        nextcloudBundle.apps.indexOf("install-nextcloud"),
      "nextcloud bundle should install Mailu before Nextcloud"
    );
  } finally {
    fs.rmSync(tempRoot, { recursive: true, force: true });
  }
});

test("uninstall jobs can merge cluster kubeconfig secrets with step secret refs", () => {
  const cluster = {
    id: "cluster-1",
    slug: "tst",
    metadata: {},
  };

  const merged = mergeSecretBundles(buildClusterWorkerSecretBundle(cluster), {
    files: {
      KUBECONFIG_FILE: buildSecretAttachmentRef(
        {
          scope: "cluster",
          item: "kubeconfig",
        },
        "kubeconfig",
        { optional: true }
      ),
    },
  });

  assert.equal(merged.files.KUBECONFIG_FILE.attachment, "kubeconfig");
  assert.equal(merged.files.TWINBOX_KUBECONFIG_FILE.attachment, "kubeconfig");
});

test("failed uninstall jobs keep apps exposed as installed in the app catalog", () => {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "twinbox-uninstall-state-"));
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
    path.join(dirs.stepState, "clusters", "cluster-1-instance", "install-immich.json"),
    JSON.stringify({
      step_id: "install-immich",
      status: "failed",
      inputs: {},
      outputs: null,
      cluster_id: "cluster-1",
      cluster_instance_id: "cluster-1-instance",
      last_job_id: "job-uninstall-1",
    })
  );
  fs.writeFileSync(
    path.join(dirs.jobs, "job-uninstall-1.json"),
    JSON.stringify({
      id: "job-uninstall-1",
      type: "uninstall_step",
      status: "failed",
      step: "failed",
    })
  );

  try {
    const appCatalog = buildAppCatalogResponse({
      workspaceRoot: process.cwd(),
      dirs,
      clusterId: "cluster-1",
    });

    const immichCard = appCatalog.categories[0].steps.find((step) => step.id === "install-immich");
    assert.equal(immichCard?.app_state, "installed");
  } finally {
    fs.rmSync(tempRoot, { recursive: true, force: true });
  }
});
