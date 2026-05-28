function iconEntry({
  stepId,
  fileBase = stepId,
  isAppOrPlatform = false,
  officialSourceType = "",
  officialSourceUrl = "",
}) {
  const entry = {
    stepId,
    fileBase,
    sourceKind: "local-svg",
    sourceFile: `./${fileBase}.svg`,
    isAppOrPlatform,
  };

  if (isAppOrPlatform) {
    entry.officialSourceType = officialSourceType;
    entry.officialSourceUrl = officialSourceUrl;
  }

  return entry;
}

export const STEP_ICON_MANIFEST = [
  iconEntry({
    stepId: "provision-nodes",
  }),
  iconEntry({
    stepId: "install-argocd",
    isAppOrPlatform: true,
    officialSourceType: "project-repository",
    officialSourceUrl: "https://github.com/argoproj/argo-cd",
  }),
  iconEntry({
    stepId: "install-longhorn-storage",
    isAppOrPlatform: true,
    officialSourceType: "project-repository",
    officialSourceUrl: "https://github.com/longhorn/longhorn",
  }),
  iconEntry({
    stepId: "install-secret-sync",
    isAppOrPlatform: true,
    officialSourceType: "project-repository",
    officialSourceUrl: "https://github.com/openbao/openbao",
  }),
  iconEntry({
    stepId: "install-traefik",
    isAppOrPlatform: true,
    officialSourceType: "project-repository",
    officialSourceUrl: "https://github.com/traefik/traefik",
  }),
  iconEntry({
    stepId: "install-cloudnativepg",
    isAppOrPlatform: true,
    officialSourceType: "project-repository",
    officialSourceUrl: "https://github.com/cloudnative-pg/cloudnative-pg",
  }),
  iconEntry({
    stepId: "install-coder",
    isAppOrPlatform: true,
    officialSourceType: "project-repository",
    officialSourceUrl: "https://github.com/coder/coder",
  }),
  iconEntry({
    stepId: "install-prometheus",
    isAppOrPlatform: true,
    officialSourceType: "project-repository",
    officialSourceUrl: "https://github.com/prometheus/prometheus",
  }),
  iconEntry({
    stepId: "install-loki",
    isAppOrPlatform: true,
    officialSourceType: "project-repository",
    officialSourceUrl: "https://github.com/grafana/loki",
  }),
  iconEntry({
    stepId: "install-authentik-idp",
    isAppOrPlatform: true,
    officialSourceType: "project-repository",
    officialSourceUrl: "https://github.com/goauthentik/authentik",
  }),
  iconEntry({
    stepId: "create-users-and-groups",
  }),
  iconEntry({
    stepId: "configure-cloudflare-dns",
  }),
  iconEntry({
    stepId: "install-whoami",
    isAppOrPlatform: true,
    officialSourceType: "project-repository",
    officialSourceUrl: "https://github.com/traefik/whoami",
  }),
  iconEntry({
    stepId: "install-headlamp",
    isAppOrPlatform: true,
    officialSourceType: "project-repository",
    officialSourceUrl: "https://github.com/headlamp-k8s/headlamp",
  }),
  iconEntry({
    stepId: "install-grafana",
    isAppOrPlatform: true,
    officialSourceType: "project-repository",
    officialSourceUrl: "https://github.com/grafana/grafana",
  }),
  iconEntry({
    stepId: "install-pgadmin4",
    isAppOrPlatform: true,
    officialSourceType: "project-repository",
    officialSourceUrl: "https://github.com/pgadmin-org/pgadmin4",
  }),
  iconEntry({
    stepId: "install-wiredoor-gateway",
    isAppOrPlatform: true,
    officialSourceType: "project-repository",
    officialSourceUrl: "https://github.com/wiredoor/wiredoor",
  }),
  iconEntry({
    stepId: "install-dashy-dashboard",
    isAppOrPlatform: true,
    officialSourceType: "project-repository",
    officialSourceUrl: "https://github.com/Lissy93/dashy",
  }),
  iconEntry({
    stepId: "install-twinbox-portal",
    isAppOrPlatform: true,
    officialSourceType: "twinbox-repository",
    officialSourceUrl: "https://github.com/harrywesterman/Twinbox/tree/main/portal",
  }),
  iconEntry({
    stepId: "install-ntfy",
    isAppOrPlatform: true,
    officialSourceType: "project-repository",
    officialSourceUrl: "https://github.com/binwiederhier/ntfy",
  }),
  iconEntry({
    stepId: "install-management-consoles",
    isAppOrPlatform: true,
    officialSourceType: "twinbox-repository",
    officialSourceUrl:
      "https://github.com/harrywesterman/Twinbox/tree/main/categories/talos-cluster/steps/install-management-consoles",
  }),
  iconEntry({
    stepId: "install-matrix",
    isAppOrPlatform: true,
    officialSourceType: "project-repository",
    officialSourceUrl: "https://github.com/element-hq/element-meta",
  }),
  iconEntry({
    stepId: "install-velero-backup",
    isAppOrPlatform: true,
    officialSourceType: "project-repository",
    officialSourceUrl: "https://github.com/vmware-tanzu/velero",
  }),
  iconEntry({
    stepId: "install-velero-ui",
    isAppOrPlatform: true,
    officialSourceType: "project-repository",
    officialSourceUrl: "https://github.com/otwld/velero-ui",
  }),
  iconEntry({
    stepId: "install-nextcloud",
    isAppOrPlatform: true,
    officialSourceType: "project-repository",
    officialSourceUrl: "https://github.com/nextcloud/server",
  }),
  iconEntry({
    stepId: "install-opencloud",
    isAppOrPlatform: true,
    officialSourceType: "project-repository",
    officialSourceUrl: "https://github.com/opencloud-eu/opencloud",
  }),
  iconEntry({
    stepId: "install-immich",
    isAppOrPlatform: true,
    officialSourceType: "project-repository",
    officialSourceUrl: "https://github.com/immich-app/immich",
  }),
  iconEntry({
    stepId: "install-zulip",
    isAppOrPlatform: true,
    officialSourceType: "project-repository",
    officialSourceUrl: "https://github.com/zulip/zulip",
  }),
  iconEntry({
    stepId: "install-paperless",
    isAppOrPlatform: true,
    officialSourceType: "project-repository",
    officialSourceUrl: "https://github.com/paperless-ngx/paperless-ngx",
  }),
  iconEntry({
    stepId: "install-karakeep",
    isAppOrPlatform: true,
    officialSourceType: "project-repository",
    officialSourceUrl: "https://github.com/karakeep-app/karakeep",
  }),
  iconEntry({
    stepId: "install-vaultwarden",
    isAppOrPlatform: true,
    officialSourceType: "project-repository",
    officialSourceUrl: "https://github.com/dani-garcia/vaultwarden",
  }),
  iconEntry({
    stepId: "install-n8n",
    isAppOrPlatform: true,
    officialSourceType: "project-repository",
    officialSourceUrl: "https://github.com/n8n-io/n8n",
  }),
  iconEntry({
    stepId: "install-openwebui",
    isAppOrPlatform: true,
    officialSourceType: "project-repository",
    officialSourceUrl: "https://github.com/open-webui/open-webui",
  }),
  iconEntry({
    stepId: "install-audiobookshelf",
    isAppOrPlatform: true,
    officialSourceType: "project-repository",
    officialSourceUrl: "https://github.com/advplyr/audiobookshelf",
  }),
  iconEntry({
    stepId: "install-freshrss",
    isAppOrPlatform: true,
    officialSourceType: "project-repository",
    officialSourceUrl: "https://github.com/FreshRSS/FreshRSS",
  }),
  iconEntry({
    stepId: "install-searxng",
    isAppOrPlatform: true,
    officialSourceType: "project-repository",
    officialSourceUrl: "https://github.com/searxng/searxng",
  }),
  iconEntry({
    stepId: "install-jitsi",
    isAppOrPlatform: true,
    officialSourceType: "project-repository",
    officialSourceUrl: "https://github.com/jitsi/jitsi-meet",
  }),
  iconEntry({
    stepId: "configure-automatic-updates",
  }),
  iconEntry({
    stepId: "install-flannel",
    isAppOrPlatform: true,
    officialSourceType: "project-repository",
    officialSourceUrl: "https://github.com/flannel-io/flannel",
  }),
  iconEntry({
    stepId: "install-adguard",
    isAppOrPlatform: true,
    officialSourceType: "project-repository",
    officialSourceUrl: "https://github.com/AdguardTeam/AdGuardHome",
  }),
  iconEntry({
    stepId: "install-mailu",
    isAppOrPlatform: true,
    officialSourceType: "project-repository",
    officialSourceUrl: "https://github.com/Mailu/Mailu",
  }),
  iconEntry({
    stepId: "provision-netbird-bastion",
    isAppOrPlatform: true,
    officialSourceType: "project-repository",
    officialSourceUrl: "https://github.com/netbirdio/netbird",
  }),
];

for (const entry of STEP_ICON_MANIFEST) {
  if (!entry.isAppOrPlatform) {
    continue;
  }

  if (!entry.officialSourceType || !entry.officialSourceUrl) {
    throw new Error(`Missing official icon source metadata for ${entry.stepId}`);
  }
}

export const STEP_ICON_MANIFEST_BY_STEP_ID = Object.fromEntries(
  STEP_ICON_MANIFEST.map((entry) => [entry.stepId, entry])
);
