import test from "node:test";
import assert from "node:assert/strict";

import { buildAdminNavigationItems, buildUserAdminViewModel } from "../src/user-admin-model.js";

test("buildAdminNavigationItems shows routes for delegated admin capabilities", () => {
  assert.equal(buildAdminNavigationItems({ isAdmin: false }).length, 0);
  assert.deepEqual(buildAdminNavigationItems({ canManageApps: true }), [
    { id: "admin-app-installs", path: "/admin/apps", label: "App installs" },
  ]);
  assert.deepEqual(buildAdminNavigationItems({ canManageUsers: true }), [
    { id: "admin-users", path: "/admin/users", label: "Users & groups" },
  ]);
  assert.deepEqual(
    buildAdminNavigationItems({
      isAdmin: true,
      canManageApps: true,
      canManageUsers: true,
      zoneName: "tst.example.com",
    }),
    [
      { id: "admin-app-installs", path: "/admin/apps", label: "App installs" },
      {
        id: "admin-management-consoles",
        url: "https://admin.tst.example.com",
        label: "Management consoles",
      },
      { id: "admin-observability", path: "/admin/observability", label: "Observability" },
      { id: "admin-cluster-updates", path: "/admin/updates", label: "Cluster updates" },
      { id: "admin-agents", path: "/admin/agents", label: "AI beheerteam" },
      { id: "admin-users", path: "/admin/users", label: "Users & groups" },
    ]
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
      {
        id: "3",
        username: "akadmin",
        name: "authentik Default Admin",
        email: "akadmin@twinbox.local",
        isActive: true,
        type: "internal",
        groupNames: ["admins"],
        groups: [{ name: "admins", label: "Admins" }],
      },
      {
        id: "4",
        username: "outpost-1",
        name: "Outpost authentik Embedded Outpost Service-Account",
        email: "",
        isActive: true,
        type: "service_account",
        groupNames: [],
        groups: [],
      },
    ],
    groups: [{ id: "10", name: "employees", label: "Employees" }],
    query: "sam",
    selectedUserId: "2",
  });

  assert.equal(viewModel.filteredUsers.length, 1);
  assert.equal(viewModel.filteredUsers[0].username, "sam");
  assert.equal(viewModel.selectedUser?.id, "2");
  assert.equal(viewModel.stats.totalUsers, 2);
  assert.equal(viewModel.stats.activeUsers, 1);
  assert.equal(viewModel.stats.inactiveUsers, 1);
  assert.equal(viewModel.groups[0].selected, false);
});
