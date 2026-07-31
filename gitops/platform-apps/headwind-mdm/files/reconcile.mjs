import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";

const baseUrl = process.env.HEADWIND_INTERNAL_URL || "http://headwind-mdm:8080";
const catalog = JSON.parse(readFileSync("/config/catalog.json", "utf8"));
const bootstrap = process.env.HEADWIND_BOOTSTRAP === "true";
const adminPassword = process.env.ADMIN_PASSWORD || "";
const deviceAdminPassword = process.env.DEVICE_ADMIN_PASSWORD || "";
const managedWebPackagePrefix = "io.twinbox.mobile.web.";

function md5(value) {
  return createHash("md5").update(value).digest("hex").toUpperCase();
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function unwrap(value) {
  if (value && typeof value === "object") {
    return value.data ?? value.result ?? value.payload ?? value;
  }
  return value;
}

function toArray(value) {
  const unwrapped = unwrap(value);
  return Array.isArray(unwrapped) ? unwrapped : [];
}

async function responseJson(response, path) {
  const text = await response.text();
  let body = null;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = text;
  }
  if (!response.ok || body?.status === "ERROR") {
    throw new Error(`${path} returned HTTP ${response.status}`);
  }
  return unwrap(body);
}

async function login(password) {
  try {
    const response = await fetch(`${baseUrl}/rest/public/auth/login`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ login: "admin", password: md5(password) }),
    });
    if (!response.ok) {
      return null;
    }
    const user = await responseJson(response, "Headwind login");
    const setCookie = response.headers.get("set-cookie") || "";
    const sessionCookie = setCookie.split(";")[0];
    if (!sessionCookie || !user || typeof user !== "object") {
      return null;
    }
    return { cookie: sessionCookie, user };
  } catch {
    return null;
  }
}

async function authenticate() {
  const initial = await login("admin");
  if (initial) {
    return { ...initial, usesInitialPassword: true };
  }
  const configured = await login(adminPassword);
  if (!configured) {
    throw new Error("Headwind administrator credentials were rejected");
  }
  return { ...configured, usesInitialPassword: false };
}

async function api(session, path, options = {}) {
  const response = await fetch(`${baseUrl}${path}`, {
    ...options,
    headers: {
      cookie: session.cookie,
      "content-type": "application/json",
      ...(options.headers || {}),
    },
  });
  return responseJson(response, path);
}

async function verifyArtifact(entry) {
  const response = await fetch(entry.url);
  if (!response.ok || !response.body) {
    throw new Error(`Could not download ${entry.name} for SHA-256 verification`);
  }
  const chunks = [];
  for await (const chunk of response.body) {
    chunks.push(chunk);
  }
  const actual = sha256(Buffer.concat(chunks));
  if (actual !== entry.sha256) {
    throw new Error(`${entry.name} SHA-256 verification failed`);
  }
}

async function installedTwinboxApplications() {
  const tokenPath = "/var/run/secrets/kubernetes.io/serviceaccount/token";
  const token = readFileSync(tokenPath, "utf8").trim();
  const response = await fetch(
    "https://kubernetes.default.svc/apis/argoproj.io/v1alpha1/namespaces/argocd/applications",
    { headers: { authorization: `Bearer ${token}` } },
  );
  const body = await responseJson(response, "Argo CD applications query");
  return new Set(
    (body.items || [])
      .filter((application) => application.status?.sync?.status === "Synced")
      .map((application) => application.metadata?.name)
      .filter(Boolean),
  );
}

async function ensureNativeApplication(session, entry, applications) {
  const existing = applications.find((application) => application.pkg === entry.packageId);
  if (existing?.version !== entry.version || existing?.url !== entry.url) {
    await verifyArtifact(entry);
    const payload = {
      ...(existing || {}),
      name: entry.name,
      pkg: entry.packageId,
      version: entry.version,
      versionCode: entry.versionCode,
      url: entry.url,
      showIcon: true,
      useKiosk: false,
      runAfterInstall: entry.runAfterInstall,
      runAtBoot: false,
      action: 1,
      skipVersion: false,
      type: "app",
    };
    const result = await api(session, "/rest/private/applications/android", {
      method: "PUT",
      body: JSON.stringify(payload),
    });
    const updated = result && typeof result === "object" ? result : payload;
    if (updated.latestVersion) {
      await api(session, "/rest/private/applications/versions", {
        method: "PUT",
        body: JSON.stringify({
          id: updated.latestVersion,
          applicationId: updated.id,
          version: entry.version,
          versionCode: entry.versionCode,
          url: entry.url,
          apkHash: entry.sha256,
        }),
      });
    }
  }
}

async function ensureWebApplication(session, shortcut, applications) {
  const packageId = `${managedWebPackagePrefix}${shortcut.id}`;
  const existing = applications.find((application) => application.pkg === packageId);
  const payload = {
    ...(existing || {}),
    name: shortcut.name,
    pkg: packageId,
    url: shortcut.url,
    showIcon: true,
    useKiosk: false,
    runAfterInstall: false,
    runAtBoot: false,
    action: 1,
    iconText: "TB",
    type: "web",
  };
  await api(session, "/rest/private/applications/web", {
    method: "PUT",
    body: JSON.stringify(payload),
  });
}

async function findConfiguration(session) {
  const configurations = toArray(await api(session, "/rest/private/configurations/search"));
  return {
    configurations,
    configuration: configurations.find((configuration) => configuration.name === catalog.configurationName),
  };
}

async function ensureConfiguration(session) {
  const { configurations, configuration } = await findConfiguration(session);
  if (configuration) {
    return configuration;
  }
  const template = configurations.find((candidate) => candidate.mainAppId) || configurations[0];
  if (!template?.mainAppId) {
    throw new Error("Headwind did not seed a launcher configuration; public enrollment remains blocked");
  }
  return api(session, "/rest/private/configurations", {
    method: "PUT",
    body: JSON.stringify({
      ...template,
      id: null,
      name: catalog.configurationName,
      description: "Twinbox-managed corporate LineageOS devices",
      password: md5(deviceAdminPassword),
      kioskMode: false,
      runDefaultLauncher: true,
      disableLocation: false,
      // MQTT needs a separate public TCP listener. HTTP polling keeps the
      // publicly exposed device surface to the TLS enrollment/API host only.
      pushOptions: "polling",
    }),
  });
}

async function reconcileCatalog(session) {
  let applications = toArray(await api(session, "/rest/private/applications/search"));
  for (const entry of catalog.nativeApps) {
    await ensureNativeApplication(session, entry, applications);
  }
  applications = toArray(await api(session, "/rest/private/applications/search"));
  const installed = bootstrap ? new Set() : await installedTwinboxApplications();
  const shortcuts = catalog.shortcuts.filter(
    (shortcut) => shortcut.required || installed.has(shortcut.application),
  );
  for (const shortcut of shortcuts) {
    await ensureWebApplication(session, shortcut, applications);
  }
  applications = toArray(await api(session, "/rest/private/applications/search"));
  const configuration = await ensureConfiguration(session);
  const desiredPackages = new Set([
    ...catalog.nativeApps.map((entry) => entry.packageId),
    ...shortcuts.map((shortcut) => `${managedWebPackagePrefix}${shortcut.id}`),
  ]);
  const currentApplications = Array.isArray(configuration.applications)
    ? configuration.applications
    : [];
  const preserved = currentApplications.filter(
    (application) => !String(application.pkg || "").startsWith(managedWebPackagePrefix),
  );
  const desired = applications.filter((application) => desiredPackages.has(application.pkg));
  const merged = [...preserved.filter((application) => !desiredPackages.has(application.pkg)), ...desired];
  await api(session, "/rest/private/configurations", {
    method: "PUT",
    body: JSON.stringify({ ...configuration, applications: merged }),
  });
}

async function main() {
  if (!adminPassword || !deviceAdminPassword) {
    throw new Error("Headwind runtime secrets are missing");
  }
  const session = await authenticate();
  if (bootstrap && session.usesInitialPassword) {
    await api(session, "/rest/private/users/superadmin/password", {
      method: "PUT",
      body: JSON.stringify({
        id: session.user.id,
        login: "admin",
        newPassword: md5(adminPassword),
      }),
    });
  }
  await ensureConfiguration(session);
  await reconcileCatalog(session);
  process.stdout.write("Headwind MDM bootstrap/catalog reconciliation completed.\n");
}

main().catch((error) => {
  process.stderr.write(`Headwind MDM reconciliation failed: ${error.message}\n`);
  process.exitCode = 1;
});
