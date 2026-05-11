function trimString(value) {
  return typeof value === "string" ? value.trim() : "";
}

function normalizeProfileId(value) {
  const profile = trimString(value).toLowerCase();
  return ["minimal", "full", "off"].includes(profile) ? profile : "full";
}

function statusTone(status) {
  switch (status) {
    case "applying":
      return "is-warning";
    case "failed":
      return "is-bad";
    case "ready":
    default:
      return "is-ok";
  }
}

function statusLabel(status) {
  switch (status) {
    case "applying":
      return "applying";
    case "failed":
      return "failed";
    case "ready":
    default:
      return "ready";
  }
}

function buildDefaultProfile(profileId, source = {}) {
  const defaults = {
    minimal: {
      label: "Minimal",
      summary: "Small-cluster mode",
      description:
        "Keep metrics, remove the log/trace/dashboard stack, and avoid Longhorn-backed observability storage.",
      accent: "#14b8a6",
      priority: "low",
    },
    full: {
      label: "Full stack",
      summary: "Complete monitoring",
      description: "Keep Prometheus, Alertmanager, Loki, Tempo, Alloy, and Grafana active.",
      accent: "#2563eb",
      priority: "default",
    },
    off: {
      label: "Off",
      summary: "Remove observability",
      description:
        "Prune the observability applications and their storage to keep the cluster quiet.",
      accent: "#ef4444",
      priority: "destructive",
    },
  };

  return {
    id: profileId,
    ...defaults[profileId],
    ...source,
    label: trimString(source?.label) || defaults[profileId].label,
    summary: trimString(source?.summary) || defaults[profileId].summary,
    description: trimString(source?.description) || defaults[profileId].description,
    warning: trimString(source?.warning) || "",
    accent: trimString(source?.accent) || defaults[profileId].accent,
    priority: trimString(source?.priority) || defaults[profileId].priority,
    impact: Array.isArray(source?.impact) ? source.impact : [],
    keeps: Array.isArray(source?.keeps) ? source.keeps : [],
    removes: Array.isArray(source?.removes) ? source.removes : [],
    footprint: source?.footprint && typeof source.footprint === "object" ? source.footprint : {},
  };
}

export function buildObservabilityViewModel({
  config = {},
  cluster = null,
  selectedProfile = null,
} = {}) {
  const observabilityConfig = config?.observability || {};
  const currentProfile = normalizeProfileId(cluster?.observability_profile);
  const activeSelection = normalizeProfileId(selectedProfile || currentProfile);
  const rawProfiles =
    observabilityConfig?.profiles && typeof observabilityConfig.profiles === "object"
      ? observabilityConfig.profiles
      : {};

  const profiles = ["minimal", "full", "off"].map((profileId) =>
    buildDefaultProfile(profileId, rawProfiles[profileId])
  );
  const profilesById = new Map(profiles.map((profile) => [profile.id, profile]));
  const currentProfileCard = profilesById.get(currentProfile) || profilesById.get("full");
  const selectedProfileCard = profilesById.get(activeSelection) || profilesById.get("full");

  return {
    eyebrow: trimString(observabilityConfig.eyebrow) || "Admin",
    title: trimString(observabilityConfig.title) || "Observability control",
    description:
      trimString(observabilityConfig.description) ||
      "Choose how much monitoring the cluster should carry.",
    footnote:
      trimString(observabilityConfig.footnote) ||
      "Metrics-server stays enabled in every mode so kubectl top keeps working.",
    clusterName: trimString(cluster?.name || cluster?.slug || cluster?.id) || "Active cluster",
    clusterId: trimString(cluster?.id),
    clusterInstanceId: trimString(cluster?.cluster_instance_id || cluster?.instance_id),
    currentProfile,
    currentProfileCard,
    currentStatus: trimString(cluster?.observability_status) || "ready",
    currentStatusTone: statusTone(cluster?.observability_status),
    currentStatusLabel: statusLabel(cluster?.observability_status),
    currentError: trimString(cluster?.observability_error),
    currentJobId: trimString(cluster?.observability_last_job_id),
    selectedProfile: activeSelection,
    selectedProfileCard,
    profiles,
    canChangeProfile: Boolean(trimString(cluster?.id)),
    isDirty: activeSelection !== currentProfile,
  };
}
