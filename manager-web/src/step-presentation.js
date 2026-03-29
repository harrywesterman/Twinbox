function trimString(value) {
  return typeof value === 'string' ? value.trim() : '';
}

function assetHref(filename) {
  return new URL(`./assets/step-icons/${filename}`, import.meta.url).href;
}

const STEP_ICON_ASSETS = {
  'provision-nodes': assetHref('provision-nodes.svg'),
  'install-flannel': assetHref('install-flannel.svg'),
  'install-argocd': assetHref('install-argocd.svg'),
  'install-longhorn-storage': assetHref('install-longhorn-storage.svg'),
  'install-secret-sync': assetHref('install-secret-sync.svg'),
  'install-traefik': assetHref('install-traefik.svg'),
  'install-whoami': assetHref('install-whoami.svg'),
  'install-headlamp': assetHref('install-headlamp.svg'),
  'install-grafana': assetHref('install-grafana.svg'),
  'install-wiredoor-gateway': assetHref('install-wiredoor-gateway.svg'),
  'install-authentik-idp': assetHref('install-authentik-idp.svg'),
  'create-users-and-groups': assetHref('create-users-and-groups.svg'),
  'configure-cloudflare-dns': assetHref('configure-cloudflare-dns.svg'),
  'install-homepage-dashboard': assetHref('install-homepage-dashboard.svg'),
  'install-management-consoles': assetHref('install-management-consoles.svg'),
  'install-velero-backup': assetHref('install-velero-backup.svg'),
  'install-proxmox-backup-system': assetHref('install-proxmox-backup-system.svg'),
  'install-nextcloud': assetHref('install-nextcloud.svg'),
  'install-immich': assetHref('install-immich.svg'),
  'install-rocketchat': assetHref('install-rocketchat.svg'),
  'install-paperless': assetHref('install-paperless.svg'),
  'install-karakeep': assetHref('install-karakeep.svg'),
  'install-gitea': assetHref('install-gitea.svg'),
  'install-uptimekuma': assetHref('install-uptimekuma.svg'),
  'install-n8n': assetHref('install-n8n.svg'),
  'install-audiobookshelf': assetHref('install-audiobookshelf.svg'),
  'install-freshrss': assetHref('install-freshrss.svg'),
  'install-jitsi': assetHref('install-jitsi.svg'),
  'configure-automatic-updates': assetHref('configure-automatic-updates.svg'),
};

function buildProjectUrlMap() {
  return {
    'provision-nodes': {
      icon: '🖥️',
      project_url: 'https://www.talos.dev/',
      github_url: 'https://github.com/siderolabs/talos',
    },
    'install-flannel': {
      icon: '🕸️',
      project_url: 'https://github.com/flannel-io/flannel',
      github_url: 'https://github.com/flannel-io/flannel',
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
    'configure-cloudflare-dns': {
      icon: '☁️',
      project_url: 'https://developers.cloudflare.com/dns/',
      github_url: 'https://github.com/cloudflare/cloudflare-docs',
    },
    'install-homepage-dashboard': {
      icon: '🏠',
      project_url: 'https://gethomepage.dev/',
      github_url: 'https://github.com/gethomepage/homepage',
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
    'install-proxmox-backup-system': {
      icon: '🗄️',
      project_url: 'https://www.proxmox.com/en/products/proxmox-backup-server',
      github_url: 'https://github.com/proxmox',
    },
    'install-nextcloud': {
      icon: '☁️',
      project_url: 'https://nextcloud.com/',
      github_url: 'https://github.com/nextcloud/server',
    },
    'install-immich': {
      icon: '🖼️',
      project_url: 'https://immich.app/',
      github_url: 'https://github.com/immich-app/immich',
    },
    'install-rocketchat': {
      icon: '💬',
      project_url: 'https://www.rocket.chat/',
      github_url: 'https://github.com/RocketChat/Rocket.Chat',
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
    'install-gitea': {
      icon: '🛠️',
      project_url: 'https://about.gitea.com/',
      github_url: 'https://github.com/go-gitea/gitea',
    },
    'install-uptimekuma': {
      icon: '⏱️',
      project_url: 'https://uptime.kuma.pet/',
      github_url: 'https://github.com/louislam/uptime-kuma',
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
    'configure-automatic-updates': {
      icon: '♻️',
      project_url: 'https://github.com/harrywesterman/twinbox/blob/main/docs/wizard-guide.md',
      github_url: 'https://github.com/harrywesterman/twinbox',
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
