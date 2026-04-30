import { STEP_ICON_MANIFEST } from './assets/step-icons/manifest.js';

function trimString(value) {
  return typeof value === 'string' ? value.trim() : '';
}

const STEP_ICON_ASSETS = Object.fromEntries(
  STEP_ICON_MANIFEST.map((entry) => [
    entry.stepId,
    new URL(`./assets/step-icons/${entry.fileBase}.svg`, import.meta.url).href,
  ]),
);

function buildProjectUrlMap() {
  return {
    'provision-nodes': {
      icon: '🖥️',
      project_url: 'https://www.talos.dev/',
      github_url: 'https://github.com/siderolabs/talos',
    },
    'install-argocd': {
      icon: '🔁',
      project_url: 'https://argo-cd.readthedocs.io/en/stable/',
      github_url: 'https://github.com/argoproj/argo-cd',
    },
    'install-longhorn-storage': {
      icon: '💾',
      project_url: 'https://longhorn.io/',
      github_url: 'https://github.com/longhorn/longhorn',
    },
    'install-secret-sync': {
      icon: '🔐',
      project_url: 'https://openbao.org/',
      github_url: 'https://github.com/openbao/openbao',
    },
    'install-crowdsec': {
      icon: '🛡️',
      project_url: 'https://www.crowdsec.net/',
      github_url: 'https://github.com/crowdsecurity/crowdsec',
    },
    'install-cloudnativepg': {
      icon: '🐘',
      project_url: 'https://cloudnative-pg.io/',
      github_url: 'https://github.com/cloudnative-pg/cloudnative-pg',
    },
    'install-traefik': {
      icon: '🧭',
      project_url: 'https://traefik.io/traefik/',
      github_url: 'https://github.com/traefik/traefik',
    },
    'install-whoami': {
      icon: '👤',
      project_url: 'https://github.com/traefik/whoami',
      github_url: 'https://github.com/traefik/whoami',
    },
    'install-headlamp': {
      icon: '🔦',
      project_url: 'https://headlamp.dev/',
      github_url: 'https://github.com/headlamp-k8s/headlamp',
    },
    'install-grafana': {
      icon: '📈',
      project_url: 'https://grafana.com/oss/grafana/',
      github_url: 'https://github.com/grafana/grafana',
    },
    'install-loki': {
      icon: '📜',
      project_url: 'https://grafana.com/oss/loki/',
      github_url: 'https://github.com/grafana/loki',
    },
    'install-tempo': {
      icon: '⏱️',
      project_url: 'https://grafana.com/oss/tempo/',
      github_url: 'https://github.com/grafana/tempo',
    },
    'install-alloy': {
      icon: '🧵',
      project_url: 'https://grafana.com/docs/alloy/latest/',
      github_url: 'https://github.com/grafana/alloy',
    },
    'install-pgadmin4': {
      icon: '🗃️',
      project_url: 'https://www.pgadmin.org/',
      github_url: 'https://github.com/pgadmin-org/pgadmin4',
    },
    'install-wiredoor-gateway': {
      icon: '🚪',
      project_url: 'https://github.com/harrywesterman/twinbox/blob/main/docs/configuration.md',
      github_url: 'https://github.com/harrywesterman/twinbox',
    },
    'install-authentik-idp': {
      icon: '🪪',
      project_url: 'https://goauthentik.io/',
      github_url: 'https://github.com/goauthentik/authentik',
    },
    'create-users-and-groups': {
      icon: '👥',
      project_url: 'https://github.com/harrywesterman/twinbox',
      github_url: 'https://github.com/harrywesterman/twinbox',
    },
    'choose-ingress-route': {
      icon: '🧭',
      project_url: 'https://github.com/harrywesterman/twinbox/blob/main/docs/wizard-guide.md',
      github_url: 'https://github.com/harrywesterman/twinbox',
    },
    'configure-cloudflare-dns': {
      icon: '☁️',
      project_url: 'https://developers.cloudflare.com/dns/',
      github_url: 'https://github.com/cloudflare/cloudflare-docs',
    },
    'install-dashy-dashboard': {
      icon: '🏁',
      project_url: 'https://dashy.to/',
      github_url: 'https://github.com/Lissy93/dashy',
    },
    'install-twinbox-portal': {
      icon: '🏠',
      project_url: 'https://github.com/harrywesterman/twinbox/blob/main/docs/configuration.md',
      github_url: 'https://github.com/harrywesterman/twinbox',
    },
    'install-ntfy': {
      icon: '🔔',
      project_url: 'https://ntfy.sh/',
      github_url: 'https://github.com/binwiederhier/ntfy',
    },
    'install-management-consoles': {
      icon: '🧰',
      project_url: 'https://k9scli.io/',
      github_url: 'https://github.com/derailed/k9s',
    },
    'install-velero-backup': {
      icon: '🛟',
      project_url: 'https://velero.io/',
      github_url: 'https://github.com/vmware-tanzu/velero',
    },
    'install-velero-ui': {
      icon: '🖥️',
      project_url: 'https://velero-ui.docs.otwld.com/',
      github_url: 'https://github.com/otwld/velero-ui',
    },
    'install-nextcloud': {
      icon: '☁️',
      project_url: 'https://nextcloud.com/',
      github_url: 'https://github.com/nextcloud/server',
    },
    'install-opencloud': {
      icon: '☁️',
      project_url: 'https://opencloud.eu/',
      github_url: 'https://github.com/opencloud-eu/opencloud',
    },
    'install-immich': {
      icon: '🖼️',
      project_url: 'https://immich.app/',
      github_url: 'https://github.com/immich-app/immich',
    },
    'install-zulip': {
      icon: '💬',
      project_url: 'https://zulip.com/',
      github_url: 'https://github.com/zulip/zulip',
    },
    'install-paperless': {
      icon: '📄',
      project_url: 'https://docs.paperless-ngx.com/',
      github_url: 'https://github.com/paperless-ngx/paperless-ngx',
    },
    'install-karakeep': {
      icon: '🔖',
      project_url: 'https://karakeep.app/',
      github_url: 'https://github.com/karakeep-app/karakeep',
    },
    'install-vaultwarden': {
      icon: '🔐',
      project_url: 'https://www.vaultwarden.net/',
      github_url: 'https://github.com/dani-garcia/vaultwarden',
    },
    'install-n8n': {
      icon: '🔗',
      project_url: 'https://n8n.io/',
      github_url: 'https://github.com/n8n-io/n8n',
    },
    'install-audiobookshelf': {
      icon: '🎧',
      project_url: 'https://audiobookshelf.org/',
      github_url: 'https://github.com/advplyr/audiobookshelf',
    },
    'install-freshrss': {
      icon: '📰',
      project_url: 'https://freshrss.org/',
      github_url: 'https://github.com/FreshRSS/FreshRSS',
    },
    'install-jitsi': {
      icon: '🎥',
      project_url: 'https://jitsi.org/',
      github_url: 'https://github.com/jitsi/jitsi-meet',
    },
    'configure-wiredoor-ingress': {
      icon: '🚪',
      project_url: 'https://wiredoor.net/',
      github_url: 'https://github.com/wiredoor/wiredoor',
    },
    'configure-cloudflare-tunnel': {
      icon: '🌐',
      project_url: 'https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/',
      github_url: 'https://github.com/cloudflare/cloudflared',
    },
    'configure-metallb-ingress': {
      icon: '⚖️',
      project_url: 'https://metallb.universe.tf/',
      github_url: 'https://github.com/metallb/metallb',
    },
    'configure-tailscale-ingress': {
      icon: '🔗',
      project_url: 'https://tailscale.com/',
      github_url: 'https://github.com/tailscale/tailscale',
    },
  };
}

const STEP_PRESENTATION_MAP = buildProjectUrlMap();

function fallbackIcon(step) {
  if (step?.journey_stage === 'manage') {
    return '⚙️';
  }

  if (step?.type === 'config') {
    return '🧩';
  }

  return '🚀';
}

function normalizeUrl(value) {
  const normalized = trimString(value);
  if (!normalized) {
    return '';
  }

  if (!/^https?:\/\//i.test(normalized)) {
    throw new Error(`presentation URLs must use http(s): ${normalized}`);
  }

  return normalized;
}

function buildPositiveSummary(step) {
  const summary = trimString(step?.summary);
  if (summary && !/placeholder/i.test(summary)) {
    return summary;
  }

  const title = trimString(step?.title) || trimString(step?.id).replace(/[-_]+/g, ' ');
  const action = title.replace(/^(Install|Configure|Deploy)\s+/i, '').trim() || title;

  if (step?.journey_stage === 'manage') {
    return `Twinbox keeps ${action} visible and applies it on the Management VM without hiding the underlying configuration.`;
  }

  return `Twinbox stages ${action} as part of the guided install flow and keeps the configuration explicit for the operator.`;
}

export function resolveStepPresentation(step = {}) {
  const preset = STEP_PRESENTATION_MAP[step.id] || {};
  const icon = trimString(step.icon) || preset.icon || fallbackIcon(step);
  const project_url = normalizeUrl(step.project_url) || preset.project_url || '';
  const github_url = normalizeUrl(step.github_url) || preset.github_url || '';

  return {
    icon,
    icon_artwork_url: STEP_ICON_ASSETS[step.id] || '',
    project_url,
    github_url,
    positive_summary: trimString(step.positive_summary) || buildPositiveSummary(step),
  };
}
