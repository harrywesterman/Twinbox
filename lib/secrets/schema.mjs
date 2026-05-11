function trimString(value) {
  return typeof value === "string" ? value.trim() : "";
}

export function defaultProxmoxSecretRef() {
  return {
    scope: "global",
    item: "proxmox",
  };
}

export function defaultClusterSecretRef(clusterId, item) {
  return {
    scope: "cluster",
    item,
    ...(clusterId ? { cluster_id: clusterId } : {}),
  };
}

export function normalizeSecretBaseRef(rawRef = {}) {
  const scope = trimString(rawRef.scope || "global");
  const item = trimString(rawRef.item);
  const clusterId = trimString(rawRef.cluster_id);

  if (!scope) {
    throw new Error("secret ref scope is required");
  }
  if (!item) {
    throw new Error("secret ref item is required");
  }

  return {
    scope,
    item,
    ...(clusterId ? { cluster_id: clusterId } : {}),
  };
}

export function normalizeSecretRef(rawRef = {}) {
  const baseRef = normalizeSecretBaseRef(rawRef);
  const field = trimString(rawRef.field);
  const attachment = trimString(rawRef.attachment);
  const format = trimString(rawRef.format || (attachment ? "file" : "text")) || "text";
  const optional = Boolean(rawRef.optional);

  if (!field && !attachment) {
    throw new Error("secret ref requires either a field or attachment");
  }

  return {
    ...baseRef,
    ...(field ? { field } : {}),
    ...(attachment ? { attachment } : {}),
    format,
    ...(optional ? { optional: true } : {}),
  };
}

export function buildSecretFieldRef(baseRef, field, overrides = {}) {
  return normalizeSecretRef({
    ...normalizeSecretBaseRef(baseRef),
    ...overrides,
    field,
  });
}

export function buildSecretAttachmentRef(baseRef, attachment, overrides = {}) {
  return normalizeSecretRef({
    ...normalizeSecretBaseRef(baseRef),
    ...overrides,
    attachment,
  });
}

export function normalizeSecretBundle(rawBundle = {}) {
  const envEntries = Object.entries(rawBundle.env || {}).map(([name, ref]) => [
    name,
    normalizeSecretRef(ref),
  ]);
  const fileEntries = Object.entries(rawBundle.files || {}).map(([name, ref]) => [
    name,
    normalizeSecretRef({
      ...ref,
      format: ref?.format || "file",
    }),
  ]);

  return {
    env: Object.fromEntries(envEntries),
    files: Object.fromEntries(fileEntries),
  };
}

export function ensureClusterSecretRefs(cluster) {
  const metadata = cluster?.metadata || {};
  const secretRefs = metadata.secret_refs || {};
  const clusterId = trimString(cluster?.id);

  return {
    ...cluster,
    metadata: {
      ...metadata,
      secret_refs: {
        ...secretRefs,
        proxmox: normalizeSecretBaseRef({
          ...defaultProxmoxSecretRef(),
          ...(secretRefs.proxmox || {}),
        }),
        talos_secrets: normalizeSecretBaseRef({
          ...defaultClusterSecretRef(clusterId, "talos-secrets"),
          ...(secretRefs.talos_secrets || {}),
        }),
        talosconfig: normalizeSecretBaseRef({
          ...defaultClusterSecretRef(clusterId, "talosconfig"),
          ...(secretRefs.talosconfig || {}),
        }),
        kubeconfig: normalizeSecretBaseRef({
          ...defaultClusterSecretRef(clusterId, "kubeconfig"),
          ...(secretRefs.kubeconfig || {}),
        }),
      },
    },
  };
}

export function resolveProxmoxSecretRef(cluster) {
  return ensureClusterSecretRefs(cluster).metadata.secret_refs.proxmox;
}

export function buildProxmoxApiSecretBundle(baseRef = defaultProxmoxSecretRef()) {
  return normalizeSecretBundle({
    env: {
      PROXMOX_HOST: buildSecretFieldRef(baseRef, "host"),
      PROXMOX_PORT: buildSecretFieldRef(baseRef, "port"),
      PROXMOX_USER: buildSecretFieldRef(baseRef, "username"),
      PROXMOX_PASSWORD: buildSecretFieldRef(baseRef, "password"),
    },
  });
}

export function buildProxmoxWorkerSecretBundle(baseRef = defaultProxmoxSecretRef()) {
  return normalizeSecretBundle({
    env: {
      PROXMOX_HOST: buildSecretFieldRef(baseRef, "host"),
      PROXMOX_PORT: buildSecretFieldRef(baseRef, "port"),
      PROXMOX_USER: buildSecretFieldRef(baseRef, "username"),
      TF_VAR_proxmox_endpoint: buildSecretFieldRef(baseRef, "endpoint"),
      TF_VAR_proxmox_username: buildSecretFieldRef(baseRef, "username"),
      TF_VAR_proxmox_password: buildSecretFieldRef(baseRef, "password"),
    },
  });
}

export function buildTalosWorkerSecretBundle(secretRefs = {}) {
  return normalizeSecretBundle({
    files: {
      TWINBOX_TALOS_SECRETS_FILE: buildSecretAttachmentRef(
        secretRefs.talos_secrets,
        "secrets.yaml",
        { optional: true }
      ),
      TWINBOX_TALOSCONFIG_FILE: buildSecretAttachmentRef(secretRefs.talosconfig, "talosconfig", {
        optional: true,
      }),
      TWINBOX_KUBECONFIG_FILE: buildSecretAttachmentRef(secretRefs.kubeconfig, "kubeconfig", {
        optional: true,
      }),
    },
  });
}

export function mergeSecretBundles(...bundles) {
  const merged = { env: {}, files: {} };

  for (const bundle of bundles) {
    const normalized = normalizeSecretBundle(bundle || {});
    Object.assign(merged.env, normalized.env);
    Object.assign(merged.files, normalized.files);
  }

  return merged;
}

export function buildClusterWorkerSecretBundle(cluster) {
  const normalized = ensureClusterSecretRefs(cluster);
  const secretRefs = normalized.metadata.secret_refs;

  return mergeSecretBundles(
    buildProxmoxWorkerSecretBundle(secretRefs.proxmox),
    buildTalosWorkerSecretBundle(secretRefs)
  );
}
