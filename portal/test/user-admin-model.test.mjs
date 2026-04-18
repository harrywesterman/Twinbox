import test from "node:test";
import assert from "node:assert/strict";

import { buildAdminNavigationItems, buildUserAdminViewModel } from "../src/user-admin-model.js";

test("buildAdminNavigationItems shows the user admin route only for admins", () => {
  assert.equal(buildAdminNavigationItems({ isAdmin: false }).length, 0);
  assert.deepEqual(
    buildAdminNavigationItems({ isAdmin: true }).map((item) => item.path),
    ["/admin", "/admin/apps", "/admin/users"],
  );
});

test("buildUserAdminViewModel returns the configured empty state when no groups are allowlisted", () => {
  const viewModel = buildUserAdminViewModel({
    config: {
      userAdmin: {
        title: "Gebruikers en groepen",
        emptyStateTitle: "Nog geen groepen",
        emptyStateDescription: "Voeg groepen toe aan de config.",
        manageableGroups: [],
      },
    },
    users: [],
    groups: [],
  });

  assert.equal(viewModel.title, "Gebruikers en groepen");
  assert.equal(viewModel.emptyState?.kind, "not-configured");
  assert.equal(viewModel.emptyState?.title, "Nog geen groepen");
});

test("buildUserAdminViewModel filters users and marks the selected group memberships", () => {
  const viewModel = buildUserAdminViewModel({
    config: {
      userAdmin: {
        manageableGroups: [{ name: "employees", label: "Employees" }],
      },
    },
    users: [
      {
        id: "1",
        username: "jane",
        name: "Jane Example",
        email: "jane@example.com",
        isActive: true,
        groupNames: ["employees"],
        groups: [{ name: "employees", label: "Employees" }],
      },
      {
        id: "2",
        username: "sam",
        name: "Sam Example",
        email: "sam@example.com",
        isActive: false,
        groupNames: [],
        groups: [],
      },
    ],
    groups: [
      { id: "10", name: "employees", label: "Employees" },
    ],
    query: "sam",
    selectedUserId: "2",
  });

  assert.equal(viewModel.filteredUsers.length, 1);
  assert.equal(viewModel.filteredUsers[0].username, "sam");
  assert.equal(viewModel.selectedUser?.id, "2");
  assert.equal(viewModel.groups[0].selected, false);
});
