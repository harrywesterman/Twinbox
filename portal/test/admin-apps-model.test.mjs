import test from "node:test";
import assert from "node:assert/strict";

import { buildAdminAppsViewModel } from "../src/admin-apps-model.js";

test("buildAdminAppsViewModel keeps all apps visible and marks install states", () => {
  const viewModel = buildAdminAppsViewModel({
    catalog: {
      active_cluster: {
        id: "cluster",
        slug: "tst",
      },
      categories: [
        {
          id: "apps",
          title: "Apps",
          summary: "Install user-facing applications and collaboration tools.",
          steps: [
            {
              id: "install-immich",
              title: "Install Immich",
              summary: "Photo and video library",
              description: "Immich on Longhorn",
              icon_artwork_url: "/assets/step-icons/install-immich.svg",
              app_state: "ready",
              placeholder: false,
              dependencies: [
                { id: "install-longhorn-storage", title: "Install Longhorn Storage", state: "done" },
              ],
            },
            {
              id: "install-paperless",
              title: "Install Paperless",
              summary: "Document archive",
              description: "Placeholder app",
              app_state: "planned",
              placeholder: true,
              dependencies: [],
            },
          ],
        },
      ],
      bundles: [
        {
          id: "media",
          title: "Media",
          summary: "Photo and video tools",
          apps: ["install-immich"],
        },
      ],
    },
    selectedAppId: "install-immich",
  });

  assert.equal(viewModel.hasCards, true);
  assert.equal(viewModel.cards.length, 2);
  assert.equal(viewModel.selectedApp.id, "install-immich");
  assert.equal(viewModel.selectedApp.app_state, "ready");
  assert.equal(viewModel.selectedApp.iconUrl, "/assets/step-icons/install-immich.svg");
  assert.equal(viewModel.selectedApp.iconAlt, "Install Immich icon");
  assert.equal(viewModel.stateCounts.ready, 1);
  assert.equal(viewModel.stateCounts.planned, 1);
  assert.equal(viewModel.bundles.length, 1);
});
