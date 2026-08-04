import importlib.util
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
APP_JSX = REPO_ROOT / "manager-web" / "src" / "App.jsx"
MANAGER_WEB_JOURNEY = REPO_ROOT / "manager-web" / "src" / "journey.js"
APPLY_CLUSTER_SCRIPT = REPO_ROOT / "scripts" / "manager" / "apply-cluster.sh"
BOOTSTRAP_SCRIPT = REPO_ROOT / "scripts" / "manager" / "bootstrap-talos.sh"
PROVISION_NODES_SCRIPT = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "provision-nodes" / "run.sh"
)
MODULE_MAIN = REPO_ROOT / "infra" / "opentofu" / "talos-proxmox" / "main.tf"
MODULE_OUTPUTS = REPO_ROOT / "infra" / "opentofu" / "talos-proxmox" / "outputs.tf"
INSTALL_SECRET_SYNC_SCRIPT = REPO_ROOT / "scripts" / "manager" / "install-secret-sync.sh"
OPENBAO_SECRET_SYNC_HELPER = REPO_ROOT / "scripts" / "manager" / "sync-openbao-global-secret.sh"
ARGO_MANAGER_SCRIPT = REPO_ROOT / "scripts" / "manager" / "install-argocd.sh"
APPLY_ARGO_APP_SCRIPT = REPO_ROOT / "scripts" / "manager" / "apply-argocd-application.sh"
RENDER_CILIUM_SCRIPT = REPO_ROOT / "scripts" / "manager" / "render-cilium-manifest.sh"
CLOUDTTY_SCRIPT = REPO_ROOT / "scripts" / "manager" / "install-cloudtty.sh"
TERMIX_STEP_MANIFEST = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-browser-ssh" / "step.yaml"
)
TERMIX_STEP_SCRIPT = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-browser-ssh" / "run.sh"
)
TERMIX_SETUP_AUTHENTIK_SCRIPT = REPO_ROOT / "scripts" / "manager" / "setup-termix-authentik.sh"
TERMIX_SETUP_SCRIPT = REPO_ROOT / "scripts" / "manager" / "setup-termix.sh"
TERMIX_CONFIGMAP = REPO_ROOT / "gitops" / "platform-apps" / "termix" / "configmap.yaml"
TERMIX_DEPLOYMENT = REPO_ROOT / "gitops" / "platform-apps" / "termix" / "deployment.yaml"
TERMIX_EXTERNALSECRET = REPO_ROOT / "gitops" / "platform-apps" / "termix" / "externalsecret.yaml"
TERMIX_INGRESSROUTE = REPO_ROOT / "gitops" / "platform-apps" / "termix" / "ingressroute.yaml"
TERMIX_APP_MANIFEST = REPO_ROOT / "gitops" / "apps" / "termix.yaml"
TERMIX_NAMESPACE = REPO_ROOT / "gitops" / "platform-apps" / "termix" / "namespace.yaml"
BESZEL_STEP_SCRIPT = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-beszel" / "run.sh"
)
PROMETHEUS_SCRIPT = REPO_ROOT / "scripts" / "manager" / "install-prometheus.sh"
RECONCILE_OBSERVABILITY_SCRIPT = REPO_ROOT / "scripts" / "manager" / "reconcile-observability.sh"
TRAEFIK_MANAGER_SCRIPT = REPO_ROOT / "scripts" / "manager" / "install-traefik-manager.sh"
OPENCLOUD_STEP_SCRIPT = REPO_ROOT / "categories" / "apps" / "steps" / "install-opencloud" / "run.sh"
DASHY_APP = REPO_ROOT / "gitops" / "apps" / "dashy.yaml"
FRESHRSS_STEP_SCRIPT = REPO_ROOT / "categories" / "apps" / "steps" / "install-freshrss" / "run.sh"
OUTLINE_STEP_SCRIPT = REPO_ROOT / "categories" / "apps" / "steps" / "install-outline" / "run.sh"
OPENWEBUI_STEP_SCRIPT = REPO_ROOT / "categories" / "apps" / "steps" / "install-openwebui" / "run.sh"
N8N_STEP_SCRIPT = REPO_ROOT / "categories" / "apps" / "steps" / "install-n8n" / "run.sh"
HEDGEDOC_STEP_SCRIPT = REPO_ROOT / "categories" / "apps" / "steps" / "install-hedgedoc" / "run.sh"
PAPERLESS_STEP_SCRIPT = REPO_ROOT / "categories" / "apps" / "steps" / "install-paperless" / "run.sh"
VAULTWARDEN_STEP_SCRIPT = (
    REPO_ROOT / "categories" / "apps" / "steps" / "install-vaultwarden" / "run.sh"
)
STIRLING_PDF_STEP_SCRIPT = (
    REPO_ROOT / "categories" / "apps" / "steps" / "install-stirling-pdf" / "run.sh"
)
PIXELFED_STEP_SCRIPT = REPO_ROOT / "categories" / "apps" / "steps" / "install-pixelfed" / "run.sh"
MASTODON_STEP_SCRIPT = REPO_ROOT / "categories" / "apps" / "steps" / "install-mastodon" / "run.sh"
MASTODON_STEP_MANIFEST = (
    REPO_ROOT / "categories" / "apps" / "steps" / "install-mastodon" / "step.yaml"
)
MASTODON_APP = REPO_ROOT / "gitops" / "apps" / "mastodon.yaml"
MASTODON_VALUES = REPO_ROOT / "gitops" / "values" / "mastodon.yaml"
MASTODON_NAMESPACE = REPO_ROOT / "gitops" / "platform-apps" / "mastodon" / "namespace.yaml"
MASTODON_PLATFORM_DIR = REPO_ROOT / "gitops" / "platform-apps" / "mastodon"
MASTODON_RUNTIME_SECRET = MASTODON_PLATFORM_DIR / "externalsecret-runtime.yaml"
MASTODON_S3_SECRET = MASTODON_PLATFORM_DIR / "externalsecret-s3.yaml"
MASTODON_DB_DIR = REPO_ROOT / "gitops" / "databases" / "mastodon"
MASTODON_DB_SECRET = MASTODON_DB_DIR / "externalsecret.yaml"
MASTODON_DB_CLUSTER = MASTODON_DB_DIR / "cluster.yaml"
MASTODON_DB_OBJECTSTORE = MASTODON_DB_DIR / "objectstore.yaml"
MATRIX_STEP_SCRIPT = REPO_ROOT / "categories" / "apps" / "steps" / "install-matrix" / "run.sh"
TWINBOX_PORTAL_APP = REPO_ROOT / "gitops" / "apps" / "twinbox-portal.yaml"
OUTLINE_APP = REPO_ROOT / "gitops" / "apps" / "outline.yaml"
OUTLINE_OPTIONAL_APP = REPO_ROOT / "gitops" / "optional-apps" / "outline.yaml"
OPENWEBUI_APP = REPO_ROOT / "gitops" / "apps" / "openwebui.yaml"
N8N_APP = REPO_ROOT / "gitops" / "apps" / "n8n.yaml"
HEDGEDOC_APP = REPO_ROOT / "gitops" / "apps" / "hedgedoc.yaml"
PAPERLESS_APP = REPO_ROOT / "gitops" / "apps" / "paperless.yaml"
PIXELFED_APP = REPO_ROOT / "gitops" / "apps" / "pixelfed.yaml"
OUTLINE_DB_KUSTOMIZATION = REPO_ROOT / "gitops" / "databases" / "outline" / "kustomization.yaml"
OPENWEBUI_DB_KUSTOMIZATION = REPO_ROOT / "gitops" / "databases" / "openwebui" / "kustomization.yaml"
N8N_DB_KUSTOMIZATION = REPO_ROOT / "gitops" / "databases" / "n8n" / "kustomization.yaml"
HEDGEDOC_DB_KUSTOMIZATION = REPO_ROOT / "gitops" / "databases" / "hedgedoc" / "kustomization.yaml"
PAPERLESS_DB_KUSTOMIZATION = REPO_ROOT / "gitops" / "databases" / "paperless" / "kustomization.yaml"
VAULTWARDEN_DB_KUSTOMIZATION = (
    REPO_ROOT / "gitops" / "databases" / "vaultwarden" / "kustomization.yaml"
)
PIXELFED_DB_KUSTOMIZATION = REPO_ROOT / "gitops" / "databases" / "pixelfed" / "kustomization.yaml"
MATRIX_APP_MANIFEST = REPO_ROOT / "gitops" / "apps" / "matrix.yaml"
MATRIX_VALUES = REPO_ROOT / "gitops" / "values" / "matrix.yaml"
MATRIX_INGRESSROUTE = REPO_ROOT / "gitops" / "platform-apps" / "matrix" / "ingressroute.yaml"
MATRIX_EXTERNALSECRET = REPO_ROOT / "gitops" / "platform-apps" / "matrix" / "externalsecret.yaml"
ARGO_STEP_SCRIPT = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-argocd" / "run.sh"
)
ADGUARD_STEP_SCRIPT = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-adguard" / "run.sh"
)
SETUP_DNS_FORWARDER_SCRIPT = REPO_ROOT / "scripts" / "manager" / "setup-dns-forwarder.sh"
NETBIRD_DNS_ZONE_SCRIPT = REPO_ROOT / "scripts" / "manager" / "netbird-dns-zone.py"
NETBIRD_DNS_NAMESERVER_SCRIPT = REPO_ROOT / "scripts" / "manager" / "netbird-dns-nameserver.py"
ARGO_STEP_MANIFEST = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-argocd" / "step.yaml"
)
CILIUM_VALUES_FILE = REPO_ROOT / "config" / "cilium-values.yaml"
HUBBLE_INGRESSROUTE = REPO_ROOT / "gitops" / "platform" / "hubble" / "ingressroute.yaml"
HUBBLE_AUTHENTIK_CALLBACK_INGRESSROUTE = (
    REPO_ROOT / "gitops" / "platform" / "hubble" / "authentik-callback-ingressroute.yaml"
)
HUBBLE_AUTHENTIK_FORWARDAUTH_MIDDLEWARE = (
    REPO_ROOT / "gitops" / "platform" / "hubble" / "authentik-forwardauth-middleware.yaml"
)
ARGOCD_CM = REPO_ROOT / "gitops" / "platform" / "argocd" / "argocd-cm.yaml"
START_MANAGER_SCRIPT = REPO_ROOT / "scripts" / "start-manager.sh"
BOOTSTRAP_VM_SCRIPT = REPO_ROOT / "scripts" / "bootstrap-vm.sh"
MANAGEMENT_IP_HELPER = REPO_ROOT / "scripts" / "manager" / "management-ip.sh"
LONGHORN_STEP_SCRIPT = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-longhorn-storage" / "run.sh"
)
CLOUDNATIVEPG_STEP_SCRIPT = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-cloudnativepg" / "run.sh"
)
LONGHORN_STEP_MANIFEST = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-longhorn-storage" / "step.yaml"
)
LONGHORN_HELPER_SCRIPT = REPO_ROOT / "scripts" / "manager" / "install-longhorn-storage.sh"
TRAEFIK_STEP_SCRIPT = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-traefik" / "run.sh"
)
CROWDSEC_STEP_SCRIPT = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-crowdsec" / "run.sh"
)
TRAEFIK_STEP_MANIFEST = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-traefik" / "step.yaml"
)
CROWDSEC_STEP_MANIFEST = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-crowdsec" / "step.yaml"
)
PROMETHEUS_STEP_MANIFEST = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-prometheus" / "step.yaml"
)
PROMETHEUS_STEP_SCRIPT = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-prometheus" / "run.sh"
)
PROMETHEUS_MANIFESTS_KUSTOMIZATION = (
    REPO_ROOT / "gitops" / "apps" / "prometheus" / "manifests" / "kustomization.yaml"
)
TWINBOX_PORTAL_STEP_SCRIPT = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-twinbox-portal" / "run.sh"
)
TRAEFIK_MANAGER_STEP_MANIFEST = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-traefik-manager" / "step.yaml"
)
TRAEFIK_MANAGER_STEP_SCRIPT = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-traefik-manager" / "run.sh"
)
INGRESS_POLICY_DOC = REPO_ROOT / "docs" / "ingress-policy.md"
CHOOSE_INGRESS_ROUTE_RUN_SCRIPT = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "choose-ingress-route" / "run.sh"
)
AUTHENTIK_STEP_MANIFEST = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-authentik-idp" / "step.yaml"
)
AUTHENTIK_STEP_SCRIPT = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-authentik-idp" / "run.sh"
)
AUTHENTIK_PASSWORDLESS_BLUEPRINT = (
    REPO_ROOT / "gitops" / "apps" / "authentik" / "manifests" / "blueprint-passwordless.yaml"
)
AUTHENTIK_HEADLAMP_MODULE_MAIN = REPO_ROOT / "infra" / "opentofu" / "authentik-headlamp" / "main.tf"
AUTHENTIK_HEADLAMP_MODULE_VARS = (
    REPO_ROOT / "infra" / "opentofu" / "authentik-headlamp" / "variables.tf"
)
AUTHENTIK_HEADLAMP_MODULE_OUTPUTS = (
    REPO_ROOT / "infra" / "opentofu" / "authentik-headlamp" / "outputs.tf"
)
AUTHENTIK_DASHY_MODULE_PROVIDERS = (
    REPO_ROOT / "infra" / "opentofu" / "authentik-dashy" / "providers.tf"
)
AUTHENTIK_DASHY_MODULE_MAIN = REPO_ROOT / "infra" / "opentofu" / "authentik-dashy" / "main.tf"
AUTHENTIK_PGADMIN4_MODULE_MAIN = REPO_ROOT / "infra" / "opentofu" / "authentik-pgadmin4" / "main.tf"
AUTHENTIK_PGADMIN4_MODULE_VARS = (
    REPO_ROOT / "infra" / "opentofu" / "authentik-pgadmin4" / "variables.tf"
)
AUTHENTIK_PGADMIN4_MODULE_OUTPUTS = (
    REPO_ROOT / "infra" / "opentofu" / "authentik-pgadmin4" / "outputs.tf"
)
AUTHENTIK_PGADMIN4_MODULE_PROVIDERS = (
    REPO_ROOT / "infra" / "opentofu" / "authentik-pgadmin4" / "providers.tf"
)
PGADMIN_STEP_MANIFEST = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-pgadmin4" / "step.yaml"
)
PGADMIN_STEP_SCRIPT = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-pgadmin4" / "run.sh"
)
IMMICH_APP = REPO_ROOT / "gitops" / "apps" / "immich.yaml"
KARAKEEP_APP = REPO_ROOT / "gitops" / "optional-apps" / "karakeep.yaml"
NEXTCLOUD_OPTIONAL_APP = REPO_ROOT / "gitops" / "optional-apps" / "nextcloud.yaml"
PGADMIN_APP = REPO_ROOT / "gitops" / "apps" / "pgadmin4.yaml"
PLATFORM_INGRESS_APP = REPO_ROOT / "gitops" / "apps" / "platform-ingress.yaml"
PGADMIN_EXTERNALSECRET = REPO_ROOT / "gitops" / "platform-apps" / "pgadmin4" / "externalsecret.yaml"
PGADMIN_SERVER_CONFIGMAP = REPO_ROOT / "gitops" / "platform-apps" / "pgadmin4" / "configmap.yaml"
PGADMIN_SYNC_SERVER_SCRIPT = REPO_ROOT / "scripts" / "manager" / "sync-pgadmin4-server.sh"
PGADMIN_INGRESSROUTE = REPO_ROOT / "gitops" / "platform-apps" / "pgadmin4" / "ingressroute.yaml"
PGADMIN_DEPLOYMENT = REPO_ROOT / "gitops" / "platform-apps" / "pgadmin4" / "deployment.yaml"
PGADMIN_PVC = REPO_ROOT / "gitops" / "platform-apps" / "pgadmin4" / "pvc.yaml"
PGADMIN_SERVICE = REPO_ROOT / "gitops" / "platform-apps" / "pgadmin4" / "service.yaml"
KARAKEEP_PLATFORM_KUSTOMIZATION = (
    REPO_ROOT / "gitops" / "platform-apps" / "karakeep" / "kustomization.yaml"
)
IMMICH_DB_KUSTOMIZATION = REPO_ROOT / "gitops" / "databases" / "immich" / "kustomization.yaml"
HEADLAMP_OIDC_EXTERNALSECRET = (
    REPO_ROOT / "gitops" / "platform-apps" / "headlamp" / "externalsecret.yaml"
)
CREATE_USERS_STEP_MANIFEST = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "create-users-and-groups" / "step.yaml"
)
CHOOSE_INGRESS_ROUTE_STEP_MANIFEST = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "choose-ingress-route" / "step.yaml"
)
WHOAMI_STEP_MANIFEST = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-whoami" / "step.yaml"
)
HEADLAMP_STEP_MANIFEST = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-headlamp" / "step.yaml"
)
GRAFANA_STEP_MANIFEST = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-grafana" / "step.yaml"
)
GRAFANA_REFRESH_HELPER = REPO_ROOT / "scripts" / "manager" / "refresh-grafana-dashboard.mjs"
WORKER_JS = REPO_ROOT / "manager-worker" / "src" / "worker.js"
NETBIRD_BASTION_STEP_MANIFEST = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "provision-netbird-bastion" / "step.yaml"
)
NETBIRD_BASTION_STEP_SCRIPT = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "provision-netbird-bastion" / "run.sh"
)
NETBIRD_INGRESS_STEP_SCRIPT = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "configure-netbird-ingress" / "run.sh"
)
NETBIRD_ADMIN_ACCESS_STEP_SCRIPT = (
    REPO_ROOT
    / "categories"
    / "talos-cluster"
    / "steps"
    / "configure-netbird-admin-access"
    / "run.sh"
)
ENSURE_NETBIRD_SERVICE_SCRIPT = REPO_ROOT / "scripts" / "manager" / "ensure-netbird-service.sh"
PATCH_NETBIRD_TRAEFIK_ALIAS_SCRIPT = (
    REPO_ROOT / "scripts" / "manager" / "patch-netbird-traefik-alias.py"
)
AUTHENTIK_NETBIRD_MODULE_VARS = (
    REPO_ROOT / "infra" / "opentofu" / "authentik-netbird" / "variables.tf"
)
AUTHENTIK_NETBIRD_MODULE_MAIN = REPO_ROOT / "infra" / "opentofu" / "authentik-netbird" / "main.tf"
AUTHENTIK_NETBIRD_MODULE_PROVIDERS = (
    REPO_ROOT / "infra" / "opentofu" / "authentik-netbird" / "providers.tf"
)
AUTHENTIK_NETBIRD_MODULE_OUTPUTS = (
    REPO_ROOT / "infra" / "opentofu" / "authentik-netbird" / "outputs.tf"
)
NETBIRD_NETWORK_MODULE_MAIN = REPO_ROOT / "infra" / "opentofu" / "netbird-network" / "main.tf"
NETBIRD_PROXY_SERVICES_MODULE_MAIN = (
    REPO_ROOT / "infra" / "opentofu" / "netbird-proxy-services" / "main.tf"
)
NETBIRD_PROXY_SERVICES_MODULE_VARS = (
    REPO_ROOT / "infra" / "opentofu" / "netbird-proxy-services" / "variables.tf"
)
NETBIRD_MODULE_VARS = REPO_ROOT / "infra" / "opentofu" / "netbird" / "variables.tf"
NETBIRD_MODULE_MAIN = REPO_ROOT / "infra" / "opentofu" / "netbird" / "main.tf"
NETBIRD_CLOUD_INIT = (
    REPO_ROOT / "infra" / "opentofu" / "netbird" / "cloud-init" / "netbird.yaml.tftpl"
)
NETBIRD_BASTION_BOOTSTRAP_TEMPLATE = (
    REPO_ROOT / "scripts" / "manager" / "netbird-bastion-bootstrap-template.sh"
)
NETBIRD_BASTION_BOOTSTRAP_RENDERER = (
    REPO_ROOT / "scripts" / "manager" / "render-netbird-bastion-bootstrap.py"
)
AUTHENTIK_INGRESSROUTE = REPO_ROOT / "gitops" / "platform" / "authentik" / "ingressroute.yaml"
AUTHENTIK_NETBIRD_FORWARDED_HEADERS_MIDDLEWARE = (
    REPO_ROOT / "gitops" / "platform" / "authentik" / "netbird-forwarded-headers-middleware.yaml"
)
TRAEFIK_NETBIRD_SERVICE = (
    REPO_ROOT / "gitops" / "platform" / "traefik" / "traefik-netbird-service.yaml"
)
NETBIRD_ROUTING_PEER_DEPLOYMENT = (
    REPO_ROOT / "gitops" / "platform-apps" / "netbird-routing-peers" / "deployment.yaml"
)
PINNED_DEFAULTS = REPO_ROOT / "config" / "pinned-defaults.sh"
ARGO_BOOTSTRAP_SCRIPT = REPO_ROOT / "gitops" / "install.sh"
LONGHORN_APP = REPO_ROOT / "gitops" / "apps" / "longhorn.yaml"
TRAEFIK_APP = REPO_ROOT / "gitops" / "apps" / "traefik.yaml"
CROWDSEC_APP = REPO_ROOT / "gitops" / "apps" / "crowdsec.yaml"
WHOAMI_APP = REPO_ROOT / "gitops" / "apps" / "whoami.yaml"
HEADLAMP_APP = REPO_ROOT / "gitops" / "apps" / "headlamp.yaml"
FRESHRSS_APP = REPO_ROOT / "gitops" / "apps" / "freshrss.yaml"
VAULTWARDEN_APP = REPO_ROOT / "gitops" / "apps" / "vaultwarden.yaml"
STIRLING_PDF_DEPLOYMENT = (
    REPO_ROOT / "gitops" / "platform-apps" / "stirling-pdf" / "deployment.yaml"
)
GRAFANA_APP = REPO_ROOT / "gitops" / "apps" / "grafana.yaml"
DATABASES_APP = REPO_ROOT / "gitops" / "apps" / "databases.yaml"
WHOAMI_DEPLOYMENT = REPO_ROOT / "gitops" / "platform-apps" / "whoami" / "deployment.yaml"
HEADLAMP_VALUES = REPO_ROOT / "gitops" / "values" / "headlamp.yaml"
LONGHORN_VALUES = REPO_ROOT / "gitops" / "values" / "longhorn.yaml"
TRAEFIK_VALUES = REPO_ROOT / "gitops" / "values" / "traefik.yaml"
CROWDSEC_VALUES = REPO_ROOT / "gitops" / "values" / "crowdsec.yaml"
GRAFANA_VALUES = REPO_ROOT / "gitops" / "values" / "grafana.yaml"
TRAEFIK_DASHBOARD_EXTERNALSECRET = (
    REPO_ROOT / "gitops" / "platform" / "traefik" / "traefik-dashboard-externalsecret.yaml"
)
CROWDSEC_BOUNCER_EXTERNALSECRET = (
    REPO_ROOT / "gitops" / "platform" / "crowdsec" / "bouncer-externalsecret.yaml"
)
TRAEFIK_CROWDSEC_BOUNCER_EXTERNALSECRET = (
    REPO_ROOT / "gitops" / "platform" / "traefik" / "crowdsec-bouncer-externalsecret.yaml"
)
ARGOCD_SERVER_TRANSPORT = (
    REPO_ROOT / "gitops" / "platform" / "traefik" / "argocd-server-transport.yaml"
)
ARGOCD_INGRESSROUTE = REPO_ROOT / "gitops" / "platform" / "traefik" / "argocd-ingressroute.yaml"
WHOAMI_INGRESSROUTE = REPO_ROOT / "gitops" / "platform-apps" / "whoami" / "ingressroute.yaml"
HEADLAMP_INGRESSROUTE = REPO_ROOT / "gitops" / "platform-apps" / "headlamp" / "ingressroute.yaml"
FRESHRSS_INGRESSROUTE = REPO_ROOT / "gitops" / "platform-apps" / "freshrss" / "ingressroute.yaml"
VAULTWARDEN_INGRESSROUTE = (
    REPO_ROOT / "gitops" / "platform-apps" / "vaultwarden" / "ingressroute.yaml"
)
GRAFANA_EXTERNALSECRET = REPO_ROOT / "gitops" / "platform-apps" / "grafana" / "externalsecret.yaml"
GRAFANA_INGRESSROUTE = REPO_ROOT / "gitops" / "platform-apps" / "grafana" / "ingressroute.yaml"
PINNED_DEFAULTS = REPO_ROOT / "config" / "pinned-defaults.sh"


def _apply_cluster_text() -> str:
    return APPLY_CLUSTER_SCRIPT.read_text(encoding="utf-8")


def _bootstrap_text() -> str:
    return BOOTSTRAP_SCRIPT.read_text(encoding="utf-8")


def _module_text() -> str:
    return MODULE_MAIN.read_text(encoding="utf-8")


def _module_outputs_text() -> str:
    return MODULE_OUTPUTS.read_text(encoding="utf-8")


def _module_variables_text() -> str:
    return (REPO_ROOT / "infra" / "opentofu" / "talos-proxmox" / "variables.tf").read_text(
        encoding="utf-8"
    )


def _install_secret_sync_text() -> str:
    return INSTALL_SECRET_SYNC_SCRIPT.read_text(encoding="utf-8")


def _openbao_secret_sync_helper_text() -> str:
    return OPENBAO_SECRET_SYNC_HELPER.read_text(encoding="utf-8")


def _argo_manager_text() -> str:
    return ARGO_MANAGER_SCRIPT.read_text(encoding="utf-8")


def _argo_step_text() -> str:
    return ARGO_STEP_SCRIPT.read_text(encoding="utf-8")


def _authentik_step_text() -> str:
    return AUTHENTIK_STEP_SCRIPT.read_text(encoding="utf-8")


def _authentik_headlamp_module_text() -> str:
    return AUTHENTIK_HEADLAMP_MODULE_MAIN.read_text(encoding="utf-8")


def _authentik_headlamp_module_vars_text() -> str:
    return AUTHENTIK_HEADLAMP_MODULE_VARS.read_text(encoding="utf-8")


def _authentik_headlamp_module_outputs_text() -> str:
    return AUTHENTIK_HEADLAMP_MODULE_OUTPUTS.read_text(encoding="utf-8")


def _authentik_dashy_module_providers_text() -> str:
    return AUTHENTIK_DASHY_MODULE_PROVIDERS.read_text(encoding="utf-8")


def _authentik_dashy_module_text() -> str:
    return AUTHENTIK_DASHY_MODULE_MAIN.read_text(encoding="utf-8")


def _authentik_pgadmin4_module_text() -> str:
    return AUTHENTIK_PGADMIN4_MODULE_MAIN.read_text(encoding="utf-8")


def _authentik_pgadmin4_module_vars_text() -> str:
    return AUTHENTIK_PGADMIN4_MODULE_VARS.read_text(encoding="utf-8")


def _authentik_pgadmin4_module_outputs_text() -> str:
    return AUTHENTIK_PGADMIN4_MODULE_OUTPUTS.read_text(encoding="utf-8")


def _authentik_pgadmin4_module_providers_text() -> str:
    return AUTHENTIK_PGADMIN4_MODULE_PROVIDERS.read_text(encoding="utf-8")


def _apply_argocd_application_text() -> str:
    return APPLY_ARGO_APP_SCRIPT.read_text(encoding="utf-8")


def _cilium_render_text() -> str:
    return RENDER_CILIUM_SCRIPT.read_text(encoding="utf-8")


def _cilium_values_text() -> str:
    return CILIUM_VALUES_FILE.read_text(encoding="utf-8")


def _cloudtty_script_text() -> str:
    return CLOUDTTY_SCRIPT.read_text(encoding="utf-8")


def _termix_step_manifest_text() -> str:
    return TERMIX_STEP_MANIFEST.read_text(encoding="utf-8")


def _termix_step_text() -> str:
    return TERMIX_STEP_SCRIPT.read_text(encoding="utf-8")


def _termix_setup_authentik_text() -> str:
    return TERMIX_SETUP_AUTHENTIK_SCRIPT.read_text(encoding="utf-8")


def _termix_setup_text() -> str:
    return TERMIX_SETUP_SCRIPT.read_text(encoding="utf-8")


def _termix_deployment_text() -> str:
    return TERMIX_DEPLOYMENT.read_text(encoding="utf-8")


def _termix_externalsecret_text() -> str:
    return TERMIX_EXTERNALSECRET.read_text(encoding="utf-8")


def _prometheus_script_text() -> str:
    return PROMETHEUS_SCRIPT.read_text(encoding="utf-8")


def _traefik_manager_script_text() -> str:
    return TRAEFIK_MANAGER_SCRIPT.read_text(encoding="utf-8")


def _pinned_defaults_text() -> str:
    return PINNED_DEFAULTS.read_text(encoding="utf-8")


def _argo_step_manifest_text() -> str:
    return ARGO_STEP_MANIFEST.read_text(encoding="utf-8")


def _longhorn_step_text() -> str:
    return LONGHORN_STEP_SCRIPT.read_text(encoding="utf-8")


def _longhorn_step_manifest_text() -> str:
    return LONGHORN_STEP_MANIFEST.read_text(encoding="utf-8")


def _crowdsec_step_text() -> str:
    return CROWDSEC_STEP_SCRIPT.read_text(encoding="utf-8")


def _crowdsec_step_manifest_text() -> str:
    return CROWDSEC_STEP_MANIFEST.read_text(encoding="utf-8")


def _longhorn_helper_text() -> str:
    return LONGHORN_HELPER_SCRIPT.read_text(encoding="utf-8")


def _argo_bootstrap_text() -> str:
    return ARGO_BOOTSTRAP_SCRIPT.read_text(encoding="utf-8")


def _whoami_deployment_text() -> str:
    return WHOAMI_DEPLOYMENT.read_text(encoding="utf-8")


def _headlamp_values_text() -> str:
    return HEADLAMP_VALUES.read_text(encoding="utf-8")


def _traefik_values_text() -> str:
    return TRAEFIK_VALUES.read_text(encoding="utf-8")


def _crowdsec_values_text() -> str:
    return CROWDSEC_VALUES.read_text(encoding="utf-8")


def _longhorn_values_text() -> str:
    return LONGHORN_VALUES.read_text(encoding="utf-8")


def _traefik_dashboard_externalsecret_text() -> str:
    return TRAEFIK_DASHBOARD_EXTERNALSECRET.read_text(encoding="utf-8")


def _crowdsec_bouncer_externalsecret_text() -> str:
    return CROWDSEC_BOUNCER_EXTERNALSECRET.read_text(encoding="utf-8")


def _traefik_crowdsec_bouncer_externalsecret_text() -> str:
    return TRAEFIK_CROWDSEC_BOUNCER_EXTERNALSECRET.read_text(encoding="utf-8")


def _headlamp_oidc_externalsecret_text() -> str:
    return HEADLAMP_OIDC_EXTERNALSECRET.read_text(encoding="utf-8")


def _grafana_values_text() -> str:
    return GRAFANA_VALUES.read_text(encoding="utf-8")


def _traefik_app_text() -> str:
    return TRAEFIK_APP.read_text(encoding="utf-8")


def _crowdsec_app_text() -> str:
    return CROWDSEC_APP.read_text(encoding="utf-8")


def _grafana_externalsecret_text() -> str:
    return GRAFANA_EXTERNALSECRET.read_text(encoding="utf-8")


def _immich_app_text() -> str:
    return IMMICH_APP.read_text(encoding="utf-8")


def _karakeep_app_text() -> str:
    return KARAKEEP_APP.read_text(encoding="utf-8")


def _pgadmin_app_text() -> str:
    return PGADMIN_APP.read_text(encoding="utf-8")


def test_apply_cluster_requires_proxmox_env():
    with tempfile.TemporaryDirectory() as td:
        cmd = [
            "bash",
            str(APPLY_CLUSTER_SCRIPT),
            "--cluster-id",
            "c1",
            "--name",
            "demo",
            "--controlplane-count",
            "1",
            "--worker-count",
            "1",
            "--cpu-cores",
            "2",
            "--memory-mb",
            "4096",
            "--disk-gb",
            "20",
            "--bridge",
            "vmbr0",
            "--start-vmid",
            "200",
            "--start-ip",
            "192.168.1.51",
            "--vip-ip",
            "192.168.1.50",
            "--node-prefix-length",
            "24",
            "--gateway-ip",
            "192.168.1.1",
            "--dns-servers",
            "1.1.1.1,8.8.8.8",
            "--dns-domain",
            "cluster.internal",
            "--proxmox-node",
            "pve",
            "--storage-pool",
            "local-lvm",
            "--file-datastore",
            "local",
            "--data-dir",
            td,
        ]
        env = {"PATH": os.environ.get("PATH", "")}
        proc = subprocess.run(cmd, env=env, capture_output=True, text=True)
        assert proc.returncode != 0
        assert "Missing environment variable" in (proc.stdout + proc.stderr)


def test_collect_state_missing_cluster_file_fails():
    with tempfile.TemporaryDirectory() as td:
        cmd = [
            "bash",
            str(REPO_ROOT / "scripts/manager/collect-state.sh"),
            "--cluster-id",
            "missing",
            "--data-dir",
            td,
        ]
        proc = subprocess.run(cmd, env=os.environ.copy(), capture_output=True, text=True)
        assert proc.returncode != 0
        assert "cluster not found" in (proc.stdout + proc.stderr)


def test_apply_cluster_uses_pinned_defaults_and_tofu():
    text = _apply_cluster_text()
    assert 'source "$WORKSPACE_ROOT/config/pinned-defaults.sh"' in text
    assert "--vm-node-map) shift 2 ;;" in text
    assert 'command -v "$TOFU_BIN"' in text
    assert '"$TOFU_BIN" -chdir="$work_module_dir" init -input=false' in text
    assert 'TOFU_PARALLELISM="${TOFU_PARALLELISM:-1}"' in text
    assert (
        '"$TOFU_BIN" -chdir="$work_module_dir" apply -input=false -auto-approve -no-color -parallelism="$TOFU_PARALLELISM" -var-file="$tfvars_file"'
        in text
    )
    assert "reboot_talos_node() {" not in text
    assert "talosctl reboot \\" not in text
    assert "Rebooting Talos nodes after disk-first switch" not in text
    assert "command -v talosctl" in text
    assert "export TF_IN_AUTOMATION=1" in text
    assert "export NO_COLOR=1" in text
    assert "command -v curl" in text
    assert "command -v xz" in text
    assert "resolve_talos_image_assets()" in text
    assert "scripts/get-talos-image-factory.sh" in text
    assert "PINNED_TALOS_IMAGE_SCHEMATIC" not in text
    assert '--preset "${TALOS_IMAGE_PRESET:-qemu-guest-agent}"' not in text
    assert "TALOS_IMAGE_PRESET" in text
    assert "TALOS_IMAGE_DISK_URL=" in text
    assert "talosctl apply-config \\" in text
    assert '--endpoints "$ip" \\' in text
    assert "retrying with cluster talosconfig" in text
    assert "Resetting Talos node ${ip} to retry config application from clean state" in text
    assert "wait_for_talos_insecure" in text
    assert "AlreadyExists desc = etcd data directory is not empty" in text
    assert "talosctl bootstrap" in text
    assert 'bootstrap_mode = "dhcp-first"' in text
    assert '"/image/default/"' not in text
    assert '!= "default"' not in text
    assert "TALOS_IMAGE_FACTORY_URL:-" not in text
    assert "TALOS_IMAGE_INSTALLER=" in text
    assert "proxmox_api_login()" in text
    assert "download_talos_image()" in text
    assert 'xz -dc "$tmp_compressed" > "$tmp_image"' in text
    assert "PROXMOX_IMPORT_FREE_SPACE_BUFFER_BYTES" in text
    assert "file_size_bytes()" in text
    assert "proxmox_get_storage_status()" in text
    assert "proxmox_talos_image_size()" in text
    assert "proxmox_require_talos_upload_space()" in text
    assert "proxmox_upload_talos_image()" in text
    assert "proxmox_verify_talos_image()" in text
    assert "proxmox_talos_image_present()" in text
    assert "upload_talos_image_to_nodes()" in text
    assert "remove_legacy_talos_file_state()" in text
    assert "Talos disk image URL not resolved" in text
    assert "validate_file_datastore_import_content()" in text
    assert 'validate_file_datastore_import_content "$FILE_DATASTORE"' in text
    assert "must allow Import content for Talos disk-image provisioning" in text
    assert '"${TF_VAR_proxmox_endpoint}/api2/json/storage/${datastore}"' in text
    assert '"${node_endpoint}/api2/json/nodes/${node}/storage/${datastore}/status"' in text
    assert '--form "content=import"' in text
    assert 'expected_volid="${datastore}:import/${image_name}"' in text
    assert 'select(.volid == $volid and .content == "import")' in text
    assert "stat -c '%s' \"$path\"" in text
    assert 'file_size_bytes "$image_path"' in text
    assert 'PROXMOX_VERIFY_MAX_ATTEMPTS="${PROXMOX_VERIFY_MAX_ATTEMPTS:-24}"' in text
    assert "has unexpected size for ${expected_volid}" in text
    assert "is ${image_size} bytes, expected ${expected_size_bytes}; retrying" in text
    assert "has insufficient free space for Talos disk image upload" in text
    assert "Uploading Talos disk image to Proxmox nodes:" in text
    assert "Uploaded Talos disk image to ${node}/${datastore}" in text
    assert "Talos disk image not visible yet on ${node}/${datastore}; retrying in ${delay}s" in text
    assert (
        'talos_image_local_path="$image_cache_dir/talos-${CLUSTER_ID}-${image_cache_key}.raw"'
        in text
    )
    assert 'talos_image_file_name="talos-${CLUSTER_ID}-${image_cache_key}.raw"' in text
    assert "Removing legacy Talos ISO resources from OpenTofu state:" in text
    assert 'state rm "${legacy_addresses[@]}"' in text
    assert "controlplane_ipv4_addresses.value" in text
    assert "worker_ipv4_addresses.value" in text
    assert "flatten_ipv4_candidates" in text or "flatten | .[]" in text
    assert "ensure_vip_is_not_dhcp_assigned" in text
    assert "Control-plane VIP ${VIP_IP} was assigned by DHCP to a VM" in text
    assert 'select(startswith("10.244.") | not)' in text
    assert "TF_VAR_proxmox_endpoint" in text
    assert "TF_VAR_proxmox_username" in text
    assert "TF_VAR_proxmox_password" in text
    assert 'PROXMOX_PASSWORD="${PROXMOX_PASSWORD:-${TF_VAR_proxmox_password:-}}" ' not in text
    assert 'PROXMOX_PASSWORD="${PROXMOX_PASSWORD:-${TF_VAR_proxmox_password:-}}"' in text
    assert "Missing environment variable: PROXMOX_PASSWORD or TF_VAR_proxmox_password" in text
    assert "proxmox_password: $proxmox_password" not in text
    assert "normalize_json_object()" in text
    assert 'cluster_file="$clusters_dir/${CLUSTER_ID}.json"' in text
    assert 'raw_vm_node_map="${VM_NODE_MAP:-}"' in text
    assert (
        "Missing vm_node_map for cluster ${CLUSTER_ID}; pass --vm-node-map from the current run"
        in text
    )
    assert "vm_node_map for cluster ${CLUSTER_ID} is not valid JSON:" in text
    assert 'vm_node_map_json="$(normalize_json_object "$raw_vm_node_map")"' in text
    assert (
        "vm_node_map for cluster ${CLUSTER_ID} is empty; pass a non-empty --vm-node-map from the current run"
        in text
    )
    assert "Loaded vm_node_map from persisted cluster file ${cluster_file}" not in text
    assert "validate_vm_node_map" in text
    assert 'log "Talos placement ${name} -> ${host}"' in text
    assert '--argjson vm_node_map "$vm_node_map_json"' in text
    assert "Talos host placement map written to tfvars" in text
    assert "vm_node_map: $vm_node_map" in text
    assert "json_array_from_csv()" in text
    assert 'json_array_from_csv "${DNS_SERVERS:-1.1.1.1,8.8.8.8}"' in text
    assert '--argjson prefix "${NODE_PREFIX_LENGTH:-24}"' in text
    assert 'if ! existing_vm_ids_output="$(proxmox_get_all_vm_ids)"; then' in text
    assert "Failed to obtain Proxmox API ticket" in text
    assert "talos_image_disk_url: $talos_image_disk_url" not in text
    assert '--arg talos_image_disk_url "$image_disk_url"' not in text
    assert "TALOS_IMAGE_DOWNLOAD_URL=" in text


def test_cilium_bootstrap_renders_inline_manifest_and_talos_patches():
    text = _apply_cluster_text()
    helper_text = _cilium_render_text()
    values_text = _cilium_values_text()
    pinned_defaults_text = _pinned_defaults_text()

    assert "command -v kubectl" in text
    assert "command -v helm" in text
    assert "render_cilium_manifest()" in text
    assert 'render_cilium_manifest "$cilium_manifest_file"' in text
    assert 'upsert_secret_artifact "cilium" "cilium-bootstrap.yaml"' in text
    assert "kubePrism:" in text
    assert "port: 7445" in text
    assert "forwardKubeDNSToHost: false" in text
    assert "cni:" in text
    assert "name: none" in text
    assert "proxy:" in text
    assert "disabled: true" in text
    assert "inlineManifests:" in text
    assert "sed 's/^/        /' \"$cilium_manifest_file\"" in text
    assert 'wait_for_kubernetes_rollout "daemonset/cilium" "kube-system" "Cilium DaemonSet"' in text
    assert (
        'wait_for_kubernetes_rollout "deployment/cilium-operator" "kube-system" "Cilium operator"'
        in text
    )
    assert 'wait_for_kubernetes_rollout "deployment/coredns" "kube-system" "CoreDNS"' in text
    assert "kube-proxy daemonset should not exist in kube-proxy-free mode" in text
    assert "helm repo add cilium https://helm.cilium.io" in helper_text
    assert "helm repo update" in helper_text
    assert "--include-crds" in helper_text
    assert "PINNED_CILIUM_CHART_VERSION" in helper_text
    assert 'if [[ -n "${CILIUM_K8S_SERVICE_HOST:-}" ]]; then' in helper_text
    assert 'if [[ -n "${CILIUM_K8S_SERVICE_PORT:-}" ]]; then' in helper_text
    assert "if ((${#helm_args[@]})); then" in helper_text
    assert re.search(r"^PINNED_CILIUM_CHART_VERSION=\S+$", pinned_defaults_text, re.M)
    assert "PINNED_CLOUDTTY_CHART_VERSION=0.8.9" in pinned_defaults_text
    assert "PINNED_TRAEFIK_MANAGER_IMAGE_TAG=v0.8.0" in pinned_defaults_text
    assert "ipam:" in values_text
    assert "mode: kubernetes" in values_text
    assert "kubeProxyReplacement: true" in values_text
    assert "bpf:" in values_text
    assert "lbExternalClusterIP: true" in values_text
    assert "socketLB:" in values_text
    assert "hostNamespaceOnly: true" in values_text
    assert (
        "The bootstrap scripts override these values with the cluster VIP/API endpoint."
        in values_text
    )
    assert "localhost during bootstrap" in values_text
    assert "cgroup:" in values_text
    assert "hostRoot: /sys/fs/cgroup" in values_text
    assert "operator:" in values_text
    assert "replicas: 1" in values_text
    assert "hubble:\n  relay:\n    enabled: true\n  ui:\n    enabled: true" in values_text
    assert "SYS_MODULE" not in values_text

    cloudtty_text = _cloudtty_script_text()
    assert 'helm upgrade --install "$RELEASE_NAME" "$CHART_NAME"' in cloudtty_text
    assert '--version "$PINNED_CLOUDTTY_CHART_VERSION"' in cloudtty_text
    assert "exposureMode: NodePort" in cloudtty_text
    assert "commandAction: bash" in cloudtty_text
    assert 'CONTROLLER_DEPLOYMENT_NAME="${RELEASE_NAME}-controller-manager"' in cloudtty_text
    assert 'wait_for_deployment "$NAMESPACE" "$CONTROLLER_DEPLOYMENT_NAME"' in cloudtty_text

    assert '--set-string "k8sServiceHost=${VIP_IP}"' in text
    assert '--set-string "k8sServicePort=6443"' in text


def test_talos_node_hostname_matches_proxmox_vm_name():
    script_text = _apply_cluster_text()
    module_text = MODULE_MAIN.read_text(encoding="utf-8")

    assert 'name      = "${var.cluster_name}-${each.key}"' in module_text
    assert 'write_node_patch "$name" "$type" "$mac" "$patch_file"' in script_text
    assert "append_hostname_config_patch()" in script_text
    assert 'echo "kind: HostnameConfig"' in script_text
    assert 'echo "hostname: ${NAME}-${name}"' in script_text
    assert 'echo "auto: off"' in script_text
    assert 'append_hostname_config_patch "$name" "$controlplane_patch_file"' in script_text
    assert 'append_hostname_config_patch "$name" "$patch_file"' in script_text
    assert 'echo "    hostname:' not in script_text


def test_longhorn_step_installs_via_argocd_and_waits_for_health():
    step_text = _longhorn_step_text()
    step_manifest_text = _longhorn_step_manifest_text()
    helper_text = _longhorn_helper_text()
    longhorn_values_text = _longhorn_values_text()

    assert "title: Install Longhorn Storage" in step_manifest_text
    assert (
        "summary: Apply the Longhorn GitOps application, make its storage class the cluster default, and enable maintenance-friendly drain settings."
        in step_manifest_text
    )
    assert "runner:" in step_manifest_text
    assert "KUBECONFIG_FILE:" in step_manifest_text
    assert "item: kubeconfig" in step_manifest_text
    assert (
        "script: categories/talos-cluster/steps/install-longhorn-storage/run.sh"
        in step_manifest_text
    )
    assert "cluster_json=\"$(printf '%s' \"$STEP_CONTEXT_JSON\" | jq -c '.cluster')\"" in step_text
    assert 'TWINBOX_CLUSTER_ID="$cluster_id"' in step_text
    assert 'TWINBOX_CLUSTER_INSTANCE_ID="$cluster_instance_id"' in step_text
    assert 'KUBE_API_SERVER="https://${controlplane_ip}:6443"' in step_text
    assert 'bash "$WORKSPACE_ROOT/scripts/manager/install-longhorn-storage.sh"' in step_text
    assert (
        'WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"'
        in step_text
    )
    assert "management-ip.sh" in helper_text
    assert 'manifest_path="$WORKSPACE_ROOT/gitops/apps/longhorn.yaml"' in helper_text
    assert (
        'longhorn_single_storageclass_manifest="$WORKSPACE_ROOT/gitops/databases/longhorn-single-storageclass.yaml"'
        in helper_text
    )
    assert "hostname -I" not in helper_text
    assert "resolve_management_vm_ip()" in MANAGEMENT_IP_HELPER.read_text(encoding="utf-8")
    assert "Installing Longhorn through Argo CD" in helper_text
    assert 'bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \\' in helper_text
    assert '--application "longhorn"' in helper_text
    assert "Applying longhorn-single StorageClass manifest" in helper_text
    assert 'kubectl apply -f "$longhorn_single_storageclass_manifest" >/dev/null' in helper_text
    assert "wait_for_storage_class" in helper_text
    assert "StorageClass/${storage_class} is available" in helper_text
    assert "make_storage_class_default" in helper_text
    assert "Marking StorageClass/${storage_class} as the default storage class" in helper_text
    assert "storageclass.kubernetes.io/is-default-class" in helper_text
    assert "storageclass.beta.kubernetes.io/is-default-class" in helper_text
    assert "is not the only default storage class" in helper_text
    assert "preUpgradeChecker:" in longhorn_values_text
    assert "jobEnabled: false" in longhorn_values_text
    assert "nodeDrainPolicy: allow-if-replica-is-stopped" in longhorn_values_text
    assert "detachManuallyAttachedVolumesWhenCordoned: true" in longhorn_values_text
    assert "global:" in longhorn_values_text
    assert "twinbox.io/role: worker" in longhorn_values_text
    assert "defaultReplicaCount: 2" in longhorn_values_text
    assert "defaultClassReplicaCount: 2" in longhorn_values_text
    assert 'storageOverProvisioningPercentage: "300"' in longhorn_values_text
    assert 'storageReservedPercentageForDefaultDisk: "10"' in longhorn_values_text
    assert 'storageMinimalAvailablePercentage: "10"' in longhorn_values_text
    assert "allowVolumeCreationWithDegradedAvailability: true" not in longhorn_values_text
    assert "allowVolumeExpansion: true" in (
        REPO_ROOT / "gitops" / "databases" / "longhorn-single-storageclass.yaml"
    ).read_text(encoding="utf-8")


def test_user_apps_are_not_part_of_bootstrap_journey():
    journey_text = MANAGER_WEB_JOURNEY.read_text(encoding="utf-8")
    setup_step_ids = journey_text.split("const FIXED_SETUP_STEP_IDS = [", 1)[1].split(
        "];",
        1,
    )[0]
    category_text = (REPO_ROOT / "categories" / "talos-cluster" / "category.yaml").read_text(
        encoding="utf-8"
    )

    for step_id in ["install-nextcloud", "install-opencloud", "install-immich"]:
        assert f"'{step_id}'" not in setup_step_ids
        assert f"- id: {step_id}" not in category_text

    assert setup_step_ids.index('"install-authentik-idp"') < setup_step_ids.index(
        '"create-users-and-groups"'
    )
    assert setup_step_ids.index('"create-users-and-groups"') < setup_step_ids.index(
        '"provision-netbird-bastion"'
    )
    assert setup_step_ids.index('"configure-netbird-admin-access"') < setup_step_ids.index(
        '"install-adguard"'
    )
    assert setup_step_ids.index('"install-twinbox-portal"') < setup_step_ids.index(
        '"install-twinbox-agents"'
    )
    assert setup_step_ids.index('"install-twinbox-agents"') < setup_step_ids.index(
        '"install-management-consoles"'
    )


def test_crowdsec_step_seeds_bouncer_secret_and_applies_gitops_app():
    step_text = _crowdsec_step_text()
    step_manifest_text = _crowdsec_step_manifest_text()
    crowdsec_app_text = _crowdsec_app_text()
    crowdsec_values_text = _crowdsec_values_text()
    crowdsec_externalsecret_text = _crowdsec_bouncer_externalsecret_text()
    crowdsec_lapi_externalsecret_text = (
        REPO_ROOT / "gitops" / "platform" / "crowdsec" / "lapi-externalsecret.yaml"
    ).read_text(encoding="utf-8")
    traefik_bouncer_externalsecret_text = _traefik_crowdsec_bouncer_externalsecret_text()

    assert "title: Install CrowdSec" in step_manifest_text
    assert "script: categories/talos-cluster/steps/install-crowdsec/run.sh" in step_manifest_text
    assert "openbao_read_global_secret_json crowdsec-bouncer" in step_text
    assert "openssl rand -hex 32" in step_text
    assert '--secret-name "crowdsec-bouncer"' in step_text
    assert '--required-keys "lapi_key"' in step_text
    assert "gitops/platform/crowdsec/bouncer-externalsecret.yaml" in step_text
    assert "gitops/platform/crowdsec/lapi-externalsecret.yaml" in step_text
    assert "gitops/platform/traefik/crowdsec-bouncer-externalsecret.yaml" in step_text
    assert "openbao_read_global_secret_json crowdsec-lapi" in step_text
    assert '--secret-name "crowdsec-lapi"' in step_text
    assert '--required-keys "csLapiSecret,registrationToken"' in step_text
    assert '--application "crowdsec"' in step_text
    assert "--no-wait" in step_text
    assert 'wait_for_resource_exists "crowdsec" "daemonset/crowdsec-agent"' in step_text
    assert "rollout restart daemonset/crowdsec-agent" in step_text
    assert "rollout status daemonset/crowdsec-agent --timeout=10m" in step_text
    assert 'wait_for_resource_ready "crowdsec" "externalsecret/crowdsec-lapi-secrets"' in step_text
    assert 'wait_for_application_ready "crowdsec"' in step_text
    assert "chart: crowdsec" in crowdsec_app_text
    assert 'targetRevision: "0.24.0"' in crowdsec_app_text
    assert "$values/gitops/values/crowdsec.yaml" in crowdsec_app_text
    assert "namespace: crowdsec" in crowdsec_app_text
    assert "managedNamespaceMetadata:" in crowdsec_app_text
    assert "pod-security.kubernetes.io/enforce: privileged" in crowdsec_app_text
    assert "pod-security.kubernetes.io/warn-version: latest" in crowdsec_app_text
    assert "container_runtime: containerd" in crowdsec_values_text
    assert "cpu: 100m" in crowdsec_values_text
    assert "memory: 128Mi" in crowdsec_values_text
    assert "memory: 256Mi" in crowdsec_values_text
    assert "cpu: 250m" in crowdsec_values_text
    assert "memory: 512Mi" in crowdsec_values_text
    assert "podName: traefik-*" in crowdsec_values_text
    assert "program: traefik" in crowdsec_values_text
    assert "value: crowdsecurity/traefik" in crowdsec_values_text
    assert "secrets:" in crowdsec_values_text
    assert "externalSecret:" in crowdsec_values_text
    assert "name: crowdsec-lapi-secrets" in crowdsec_values_text
    assert "BOUNCER_KEY_traefik" in crowdsec_values_text
    assert "secretKeyRef:" in crowdsec_values_text
    assert "value: " not in crowdsec_externalsecret_text
    assert "key: twinbox/global/crowdsec-bouncer" in crowdsec_externalsecret_text
    assert "property: lapi_key" in crowdsec_externalsecret_text
    assert "kind: ExternalSecret" in crowdsec_lapi_externalsecret_text
    assert "name: openbao" in crowdsec_lapi_externalsecret_text
    assert "secretKey: csLapiSecret" in crowdsec_lapi_externalsecret_text
    assert "secretKey: registrationToken" in crowdsec_lapi_externalsecret_text
    assert "key: twinbox/global/crowdsec-lapi" in crowdsec_lapi_externalsecret_text
    assert "property: csLapiSecret" in crowdsec_lapi_externalsecret_text
    assert "property: registrationToken" in crowdsec_lapi_externalsecret_text
    assert "secretKey: lapi-key" in traefik_bouncer_externalsecret_text
    assert "key: twinbox/global/crowdsec-bouncer" in traefik_bouncer_externalsecret_text


def test_opencloud_step_keeps_authentik_property_mapping_ids_as_strings():
    text = OPENCLOUD_STEP_SCRIPT.read_text(encoding="utf-8")

    assert 'opencloud_property_mapping_ids_json="$(' in text
    assert '--arg openid "$openid_mapping_id"' in text
    assert '--arg email "$email_mapping_id"' in text
    assert '--arg profile "$profile_mapping_id"' in text
    assert '--arg roles "$roles_mapping_id"' in text
    assert "property_mappings: $property_mappings" in text
    assert (
        "property_mappings: [($openid | tonumber), ($email | tonumber), ($profile | tonumber), ($roles | tonumber)]"
        not in text
    )


def test_opencloud_step_enables_external_idp_autoprovisioning_and_ldap_checks():
    text = OPENCLOUD_STEP_SCRIPT.read_text(encoding="utf-8")

    for expected in [
        'opencloud_proxy_autoprovision_accounts="true"',
        'opencloud_proxy_autoprovision_claim_username="preferred_username"',
        'opencloud_proxy_user_oidc_claim="preferred_username"',
        'opencloud_proxy_user_cs3_claim="username"',
        'opencloud_proxy_oidc_rewrite_wellknown="true"',
        'opencloud_proxy_role_assignment_driver="oidc"',
        'opencloud_graph_assign_default_user_role="false"',
        'opencloud_graph_username_match="none"',
        'opencloud_oc_exclude_run_services="idp"',
        'opencloud_oc_ldap_disable_user_mechanism="none"',
        'opencloud_oc_ldap_insecure="true"',
        'opencloud_webfinger_web_scopes="openid profile email roles"',
        'opencloud_webfinger_desktop_scopes="openid profile email roles offline_access"',
        'opencloud_webfinger_android_scopes="openid profile email roles offline_access"',
        'opencloud_webfinger_ios_scopes="openid profile email roles offline_access"',
        'opencloud_web_scope="openid profile email roles"',
        'COLLABORA_HOST="https://opencloud-collabora.${public_zone_name}"',
        'WOPISERVER_HOST="https://opencloud-wopiserver.${public_zone_name}"',
        "PROXY_AUTOPROVISION_ACCOUNTS: $PROXY_AUTOPROVISION_ACCOUNTS",
        "PROXY_AUTOPROVISION_CLAIM_USERNAME: $PROXY_AUTOPROVISION_CLAIM_USERNAME",
        "PROXY_USER_OIDC_CLAIM: $PROXY_USER_OIDC_CLAIM",
        "PROXY_USER_CS3_CLAIM: $PROXY_USER_CS3_CLAIM",
        "PROXY_OIDC_REWRITE_WELLKNOWN: $PROXY_OIDC_REWRITE_WELLKNOWN",
        "PROXY_ROLE_ASSIGNMENT_DRIVER: $PROXY_ROLE_ASSIGNMENT_DRIVER",
        "GRAPH_ASSIGN_DEFAULT_USER_ROLE: $GRAPH_ASSIGN_DEFAULT_USER_ROLE",
        "GRAPH_USERNAME_MATCH: $GRAPH_USERNAME_MATCH",
        "OC_EXCLUDE_RUN_SERVICES: $OC_EXCLUDE_RUN_SERVICES",
        'wait_for_resources_ready "opencloud" "externalsecret" "Ready" "OpenCloud ExternalSecret"',
        "wait_for_opencloud_ldap_directory",
        "apply-argocd-application.sh",
        '--application "opencloud"',
    ]:
        assert expected in text

    assert 'kubectl apply -k "$opencloud_rendered_overlay"' not in text

    assert '"preferred_username": request.user.username' in text
    assert '"sub": request.user.uid' in text
    assert "ldapsearch -H ldaps://127.0.0.1:1636" in text


def test_opencloud_step_creates_authentik_applications_for_mobile_and_desktop_clients():
    text = OPENCLOUD_STEP_SCRIPT.read_text(encoding="utf-8")

    for client_name, slug in [
        ("OpenCloud Desktop", "opencloud-desktop"),
        ("OpenCloud Android", "opencloud-android"),
        ("OpenCloud iOS", "opencloud-ios"),
        ("Cyberduck", "opencloud-cyberduck"),
    ]:
        assert f'"{client_name}"' in text
        assert f'slug="{slug}"' in text

    assert 'application_payload="$(' in text
    assert 'application_pk="$(create_or_update_application' in text
    assert 'fail "Authentik did not return an application ID for ${provider_name}"' in text


def test_opencloud_step_includes_offline_access_scope_mapping():
    text = OPENCLOUD_STEP_SCRIPT.read_text(encoding="utf-8")

    assert "upsert_scope_mapping \\" in text
    assert '"OpenCloud offline_access"' in text
    assert '"offline_access"' in text
    assert '"Enable refresh tokens for OpenCloud clients"' in text
    assert "'return {}'" in text
    assert 'offline_access_mapping_id="$(upsert_scope_mapping' in text
    assert "[$openid, $email, $profile, $roles, $offline_access]" in text


def test_opencloud_step_uses_application_issuer_with_per_provider():
    text = OPENCLOUD_STEP_SCRIPT.read_text(encoding="utf-8")

    assert 'issuer_mode: "global"' not in text
    assert 'issuer_mode: "per_provider"' in text
    assert 'opencloud_oc_oidc_issuer="${AUTHENTIK_HOST}/application/o/opencloud/"' in text


def test_opencloud_gitops_uses_schema_backed_writable_ldap_bootstrap():
    platform_dir = REPO_ROOT / "gitops" / "platform-apps" / "opencloud"
    kustomization_text = (platform_dir / "kustomization.yaml").read_text(encoding="utf-8")
    bootstrap_text = (platform_dir / "ldap-bootstrap-configmap.yaml").read_text(encoding="utf-8")
    statefulset_text = (platform_dir / "statefulset.yaml").read_text(encoding="utf-8")
    deployment_text = (platform_dir / "deployment.yaml").read_text(encoding="utf-8")
    externalsecret_text = (platform_dir / "externalsecret.yaml").read_text(encoding="utf-8")

    assert "ldap-bootstrap-configmap.yaml" in kustomization_text
    assert "name: opencloud-ldap-bootstrap" in bootstrap_text
    assert "10_opencloud_schema.ldif" in bootstrap_text
    assert "NAME 'openCloudUUID'" in bootstrap_text
    assert "dn: ou=users,dc=opencloud,dc=eu" in bootstrap_text
    assert "dn: ou=groups,dc=opencloud,dc=eu" in bootstrap_text
    assert "LDAP_USERS" not in statefulset_text
    assert "LDAP_PASSWORDS" not in statefulset_text
    assert "key: OC_LDAP_BIND_PASSWORD" in statefulset_text
    assert "mountPath: /schemas/10_opencloud_schema.ldif" in statefulset_text
    assert "mountPath: /ldifs/10_base.ldif" in statefulset_text
    assert "name: wait-for-ldap" in deployment_text
    assert 'ldapsearch -H "$OC_LDAP_URI"' in deployment_text

    for secret_key in [
        "OC_LDAP_INSECURE",
        "PROXY_AUTOPROVISION_ACCOUNTS",
        "PROXY_AUTOPROVISION_CLAIM_USERNAME",
        "PROXY_USER_OIDC_CLAIM",
        "PROXY_USER_CS3_CLAIM",
        "PROXY_OIDC_REWRITE_WELLKNOWN",
        "PROXY_ROLE_ASSIGNMENT_DRIVER",
        "GRAPH_ASSIGN_DEFAULT_USER_ROLE",
        "GRAPH_USERNAME_MATCH",
        "OC_EXCLUDE_RUN_SERVICES",
    ]:
        assert f"secretKey: {secret_key}" in externalsecret_text
        assert f"property: {secret_key}" in externalsecret_text


def test_opencloud_pvc_sizes_match_the_live_bound_volumes():
    pvc_text = (REPO_ROOT / "gitops" / "platform-apps" / "opencloud" / "pvc.yaml").read_text(
        encoding="utf-8"
    )

    assert "name: opencloud-config" in pvc_text
    assert "name: opencloud-data" in pvc_text
    assert "name: opencloud-apps" in pvc_text
    assert "name: opencloud-radicale-data" in pvc_text
    assert pvc_text.count("storage: 20Gi") == 2
    assert pvc_text.count("storage: 50Gi") == 2


def test_apply_cluster_renders_dhcp_first_talos_flow_and_tracks_iac_paths():
    text = _apply_cluster_text()
    assert 'helper_output="$("$WORKSPACE_ROOT/scripts/get-talos-image-factory.sh"' in text
    assert '--preset "$talos_image_preset"' in text
    assert "--output shell" in text
    assert "while IFS= read -r line; do" in text
    assert "TALOS_IMAGE_INSTALLER=" in text
    assert "TALOS_IMAGE_DOWNLOAD_URL=" in text
    assert 'cp -R "$MODULE_SOURCE/." "$work_module_dir/"' in text
    assert (
        'image_cache_key="${image_platform}-${image_arch}-${image_schematic}-${PINNED_TALOS_VERSION}"'
        in text
    )
    assert "Talos disk image URL not resolved" in text
    assert 'download_talos_image "$talos_image_local_path"' in text
    assert (
        'upload_talos_image_to_nodes "$talos_image_local_path" "$talos_image_file_name" "$target_nodes_json"'
        in text
    )
    assert "nodes: $nodes" in text
    assert "planned_controlplane_ips" in text
    assert "discovered_controlplane_ips" in text
    assert "generate_talos_configs()" in text
    assert "discover_node_ip()" in text
    assert "Guest agent reported ${label} at ${candidate}" in text
    assert "Discovering control plane DHCP addresses" in text
    assert "Applying control plane Talos configs" in text
    assert "Control planes are healthy; discovering worker DHCP addresses" in text
    assert "Applying worker Talos configs" in text
    assert 'jq -Rn --arg csv "$csv"' in text
    assert 'split(",")' in text
    assert 'map(gsub("^\\\\s+|\\\\s+$"; ""))' in text
    assert "map(select(length > 0))" in text
    assert "normalize_json_object()" in text
    assert 'vm_node_map_json="$(normalize_json_object "${VM_NODE_MAP:-{}}")"' in text
    assert '--argjson vm_node_map "$vm_node_map_json"' in text
    assert "wait_for_talos_api()" in text
    assert "bootstrap_cluster()" in text
    assert "sync_user_kubeconfig()" in text
    assert "sync_user_talosconfig()" in text
    assert 'talosctl config node "$default_node_ip"' in text
    assert 'talosctl config endpoint "$default_node_ip"' in text
    assert "Reusing existing OpenTofu workspace at ${work_module_dir}" in text
    assert 'echo "    image: ${image_installer}"' in text
    assert 'image_installer="${line#TALOS_IMAGE_INSTALLER=}"' in text
    assert "image_extensions=" not in text
    assert "TALOS_IMAGE_EXTENSIONS=" not in text
    assert text.index("Applying control plane Talos configs") < text.index(
        'bootstrap_cluster "$first_controlplane_ip"'
    )
    assert text.index('bootstrap_cluster "$first_controlplane_ip"') < text.index(
        "Control planes are healthy; discovering worker DHCP addresses"
    )
    assert text.index("Control planes are healthy; discovering worker DHCP addresses") < text.index(
        "Applying worker Talos configs"
    )


def test_provision_nodes_step_returns_refs_not_kubeconfig_paths():
    text = PROVISION_NODES_SCRIPT.read_text(encoding="utf-8")
    assert "secret_refs: .metadata.secret_refs" in text
    assert "kubeconfig_path" not in text
    assert "Using ${effective_vm_node_map_source} vm_node_map:" in text
    assert 'VM_NODE_MAP="$effective_vm_node_map" bash scripts/manager/apply-cluster.sh \\' in text
    assert '--vm-node-map "$effective_vm_node_map"' in text


def test_manager_worker_image_includes_talos_image_factory_helper():
    text = (REPO_ROOT / "manager-worker" / "Dockerfile").read_text(encoding="utf-8")
    refresh_dashy_text = (
        REPO_ROOT / "manager-worker" / "src" / "refresh-dashy-config.mjs"
    ).read_text(encoding="utf-8")
    refresh_portal_text = (
        REPO_ROOT / "manager-worker" / "src" / "refresh-portal-config.mjs"
    ).read_text(encoding="utf-8")

    assert "PINNED_TALOS_VERSION" in text
    assert "talosctl-linux-amd64" in text
    assert "COPY docker-compose.yml ./docker-compose.yml" in text
    assert "COPY lib ./lib" in text
    assert "manager-api/src/lib/catalog-definitions.mjs" not in text
    assert "../../lib/catalog-definitions.mjs" in refresh_dashy_text
    assert "../../lib/catalog-definitions.mjs" in refresh_portal_text
    assert "../../manager-api/src/lib/catalog-definitions.mjs" not in refresh_dashy_text
    assert "../../manager-api/src/lib/catalog-definitions.mjs" not in refresh_portal_text
    for package in ["bash", "docker-cli", "docker-cli-compose", "iptables", "iproute2", "jq"]:
        assert package in text
    assert "COPY scripts/get-talos-image-factory.sh ./scripts/get-talos-image-factory.sh" in text
    assert "RUN chmod +x ./scripts/get-talos-image-factory.sh" in text


def test_apply_cluster_uses_deterministic_mac_addresses_and_node_inventory():
    text = _apply_cluster_text()
    assert "deterministic_mac()" in text
    assert "printf '52:54:%02x:%02x:%02x:%02x\\n'" in text
    assert "type: $type" in text
    assert "mac: $mac" in text
    assert '--file-datastore) FILE_DATASTORE="$2"; shift 2 ;;' in text
    assert "file_datastore: $file_datastore" in text


def test_bootstrap_talos_uses_discovered_ips_and_records_runtime_state():
    text = _bootstrap_text()
    assert "(.discovered_controlplane_ips // .controlplane_ips // [])[]" in text
    assert "(.discovered_worker_ips // .worker_ips // [])[]" in text
    assert "talosctl bootstrap" in text
    assert "talosctl kubeconfig" in text
    assert "qm guest cmd" not in text
    assert "detach_all_vm_isos" not in text


def test_install_secret_sync_renders_argocd_values_and_applies_secret_sync_manifests():
    text = _install_secret_sync_text()
    assert 'source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"' in text
    assert "scripts/manager/apply-argocd-application.sh" in text
    assert '--manifest "$WORKSPACE_ROOT/gitops/apps/external-secrets.yaml"' in text
    assert '--application "external-secrets"' in text
    assert "mktemp" in text
    assert "helm:" in text
    assert "values: |" in text
    assert "sed 's/^/          /' \"$OPENBAO_VALUES_FILE\"" in text
    assert '--application "openbao"' in text
    assert "--no-wait" in text
    assert "repoURL: https://openbao.github.io/openbao-helm" in text
    assert "chart: openbao" in text
    assert 'targetRevision: "0.28.4"' in text
    assert "gitops/apps/openbao.yaml" not in text
    assert "detect_openbao_replicas() {" in text
    assert "printf '1\\n'" in text
    assert "openbao_repair_kubernetes_auth" in text
    assert (
        'openbao_wait_for_external_secret_ready "$TARGET_NAMESPACE" "$EXTERNAL_SECRET_NAME"' in text
    )


def test_optional_app_helper_enables_labels_before_waiting_for_readiness():
    text = _apply_argocd_application_text()

    assert "set-optional-app-state.sh" in text
    assert 'wait_for_application_ready "$APPLICATION_NAME"' in text
    assert text.index("set-optional-app-state.sh") < text.index(
        'wait_for_application_ready "$APPLICATION_NAME"'
    )
    assert text.index("set-optional-app-state.sh") < text.index(
        'kubectl annotate application "$APPLICATION_NAME"'
    )
    assert "bw " not in text
    assert "KUBECONFIG_FILE is required" in text


def test_openbao_secret_sync_helper_uses_shared_library_and_port_forward_writeback():
    text = _openbao_secret_sync_helper_text()
    assert 'source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"' in text
    assert "Usage: sync-openbao-global-secret.sh --secret-name NAME --json-file PATH" in text
    assert (
        'openbao_sync_global_secret_file "$SECRET_NAME" "$JSON_FILE" "${required_key_list[@]}"'
        in text
    )


def test_argo_manager_script_requires_kubeconfig_and_calls_gitops_bootstrap():
    text = _argo_manager_text()
    assert "Usage: $0 [--kube-api-server URL]" in text
    assert 'KUBE_API_SERVER=""' in text
    assert "--kube-api-server" in text
    assert "Rewriting kubeconfig cluster" in text
    assert (
        'kubectl config set-cluster "$kube_cluster_name" --kubeconfig "$KUBECONFIG_FILE" --server "$KUBE_API_SERVER" >/dev/null'
        in text
    )
    assert "Bootstrapping Argo CD" in text
    assert 'bash "$WORKSPACE_ROOT/gitops/install.sh"' in text
    assert "KUBECONFIG_FILE is required" in text


def test_apply_argocd_application_helper_applies_and_waits_for_health():
    text = _apply_argocd_application_text()

    assert (
        "Usage: $0 --manifest PATH --application NAME [--destination-namespace NAMESPACE] [--skip-namespace-baseline] [--no-wait]"
        in text
    )
    assert "cluster_resource_profile()" in text
    assert "namespace_resource_baseline()" in text
    assert "extract_destination_namespace()" in text
    assert "Applying namespace resource baseline to" in text
    assert "kind: LimitRange" in text
    assert "defaultRequest:" in text
    assert "default:" in text
    assert "printf '%s\\n' \"$rendered_manifest\" | kubectl apply --validate=false -f -" in text
    assert 'kubectl -n argocd get application "$application" -o json' in text
    assert 'select((.type // "") == "ComparisonError" or (.type // "" | test("Error$")))' in text
    assert "Application/${application} compare/spec error:" in text
    assert "Application/${application} is Synced and Healthy" in text
    assert "Application/${application} is Synced and has no unhealthy resources" in text
    assert '( "$health_status" == "Unknown" || "$health_status" == "Degraded" )' in text
    assert "has_unhealthy_resources()" in text
    assert "--skip-namespace-baseline" in text
    assert "Skipping namespace resource baseline for" in text
    assert "--no-wait" in text
    assert ".resource_profile // empty" in text
    assert "(.worker_count // 0)" in text


def test_stirling_pdf_waits_for_real_kubernetes_readiness():
    step_text = STIRLING_PDF_STEP_SCRIPT.read_text(encoding="utf-8")
    deployment_text = STIRLING_PDF_DEPLOYMENT.read_text(encoding="utf-8")
    ingressroute_text = (
        REPO_ROOT / "gitops" / "platform-apps" / "stirling-pdf" / "ingressroute.yaml"
    ).read_text(encoding="utf-8")
    middleware_text = (
        REPO_ROOT
        / "gitops"
        / "platform-apps"
        / "stirling-pdf"
        / "authentik-forwardauth-middleware.yaml"
    ).read_text(encoding="utf-8")

    assert '--application "stirling-pdf" \\' in step_text
    assert "--no-wait" in step_text
    assert (
        'wait_for_resource_ready "stirling-pdf" "externalsecret/stirling-pdf-config" "Ready" "Stirling PDF ExternalSecret"'
        in step_text
    )
    assert (
        'wait_for_pvc_bound "stirling-pdf" "stirling-pdf-data" "Stirling PDF data PVC"' in step_text
    )
    assert (
        'wait_for_deployment_rollout "stirling-pdf" "stirling-pdf" "Stirling PDF application"'
        in step_text
    )
    assert (
        "desired=${desired_replicas}, updated=${updated_replicas}, ready=${ready_replicas}, available=${available_replicas}"
        in step_text
    )
    assert "tcpSocket:" in deployment_text
    assert "SECURITY_CUSTOMGLOBALAPIKEY" in deployment_text
    assert "ST_API_KEY_FOR_QR_CODE" not in deployment_text
    assert "mountPath: /configs" in deployment_text
    assert "subPath: configs" in deployment_text
    assert "mountPath: /customFiles" in deployment_text
    assert "mountPath: /logs" in deployment_text
    assert "mountPath: /usr/local/tomcat/static" not in deployment_text
    assert "SECURITY_ENABLELOGIN" in deployment_text
    assert "false" in deployment_text
    assert "SECURITY_OAUTH2_ENABLED" not in deployment_text
    assert "authentik-forwardauth" in ingressroute_text
    assert "authentik-forwardauth" in middleware_text
    assert "authentik-server" in middleware_text
    assert 'source "$WORKSPACE_ROOT/scripts/manager/authentik-auth.sh"' in step_text
    assert "authentik_ensure_token" in step_text
    assert "authentik_setup_forward" in step_text
    assert 'authentik_api_request POST "/providers/proxy/"' in step_text
    assert 'authentik_api_request POST "/core/applications/"' in step_text
    assert 'authentik_api_request POST "/policies/bindings/"' in step_text
    assert 'authentik_api_request GET "/outposts/instances/?page_size=100"' in step_text
    assert "authentik_teardown_forward" in step_text
    assert "forward_single" in step_text


def test_argo_step_script_bootstraps_argocd_without_cni_adoption():
    text = _argo_step_text()
    assert 'WORKSPACE_ROOT="${WORKSPACE_ROOT:-' in text
    assert "discovered_controlplane_ips[0]" in text
    assert (
        'bash "$WORKSPACE_ROOT/scripts/manager/install-argocd.sh" --kube-api-server "https://${controlplane_ip}:6443"'
        in text
    )
    assert "apply-argocd-application.sh" not in text
    assert '--arg application "argocd"' in text
    assert "application: $application" in text


def test_argo_bootstrap_script_installs_argocd_without_root_application_tree():
    text = _argo_bootstrap_text()
    assert "Creating argocd namespace" in text
    assert "Installing Argo CD" in text
    assert (
        "kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply --validate=false -f -"
        in text
    )
    assert (
        'kubectl apply --server-side --force-conflicts --validate=false -n argocd -f "https://raw.githubusercontent.com/argoproj/argo-cd/v${ARGOCD_VERSION}/manifests/ha/install.yaml"'
        in text
    )
    assert "control_plane_tolerations" in text
    assert "kubectl -n argocd get statefulset -o name 2>/dev/null | sort" in text
    assert "kubectl -n argocd patch" in text
    assert "patch_argocd_workload_probes()" in text
    assert "Patching ${resource} liveness probe for single-node bootstrap" in text
    assert "--type strategic -p" in text
    assert '"initialDelaySeconds":300' in text
    assert "patch_argocd_repo_server_copyutil()" in text
    assert "Patching ${resource} copyutil init container for idempotent startup" in text
    assert "/bin/ln -sfn /var/run/argocd/argocd /var/run/argocd/argocd-cmp-server" in text
    assert "wait_for_available()" in text
    assert "Waiting for ${resource} to become available" in text
    assert 'kubectl -n argocd wait --for=condition=Available "$resource" --timeout=900s' in text
    assert "wait_for_statefulset_rollout()" in text
    assert 'kubectl -n argocd rollout status "$resource" --timeout=900s' in text
    assert (
        "for resource in $(kubectl -n argocd get statefulset -o name 2>/dev/null | sort); do"
        in text
    )
    assert "wait_for_application_ready()" not in text
    assert "wait_for_root_applications()" not in text
    assert "deployment/argocd-applicationset-controller" not in text
    assert "grep -E '(^|/)argocd-repo-server($|-)'" in text
    assert "statefulset/argocd-application-controller" not in text
    assert "Applying core Argo root application" not in text
    assert "gitops/argocd/root.yaml" not in text


def test_bootstrap_apps_tolerate_single_node_control_plane():
    headlamp_text = _headlamp_values_text()

    assert "tolerations:" in headlamp_text
    assert "node-role.kubernetes.io/control-plane" in headlamp_text
    assert "node-role.kubernetes.io/master" in headlamp_text
    assert "config:" in headlamp_text
    assert "oidc:" in headlamp_text
    assert "externalSecret:" in headlamp_text
    assert "headlamp-oidc" in headlamp_text


def test_install_argocd_step_bootstraps_argocd_without_cni_adoption():
    text = _argo_step_manifest_text()

    assert (
        "summary: Install Argo CD so the remaining platform services can be managed declaratively."
        in text
    )
    assert "Talos/Cilium bootstrap" in text
    assert "Talos networking layer" not in text
    assert "root application tree" not in text


def test_app_step_manifests_chain_the_linear_gitops_flow():
    argocd_text = ARGO_STEP_MANIFEST.read_text(encoding="utf-8")
    traefik_text = TRAEFIK_STEP_MANIFEST.read_text(encoding="utf-8")
    authentik_run_text = _authentik_step_text()
    choose_ingress_text = CHOOSE_INGRESS_ROUTE_STEP_MANIFEST.read_text(encoding="utf-8")
    headlamp_text = HEADLAMP_STEP_MANIFEST.read_text(encoding="utf-8")
    grafana_text = GRAFANA_STEP_MANIFEST.read_text(encoding="utf-8")
    prometheus_text = PROMETHEUS_STEP_MANIFEST.read_text(encoding="utf-8")
    netbird_bastion_text = NETBIRD_BASTION_STEP_MANIFEST.read_text(encoding="utf-8")

    assert "install-flannel" not in argocd_text

    assert "title: Install Traefik" in traefik_text

    assert "type: config" in choose_ingress_text
    assert "label: Cloudflare" in choose_ingress_text
    assert "value: cloudflare-tunnel" in choose_ingress_text
    assert "label: NetBird" in choose_ingress_text
    assert "value: netbird" in choose_ingress_text
    assert "value: wiredoor" not in choose_ingress_text
    assert "value: metallb" not in choose_ingress_text
    assert "value: tailscale" not in choose_ingress_text
    assert "dns_domain" not in choose_ingress_text
    assert "DNS Domain" not in choose_ingress_text
    assert "Cloudflare is shown only for prd clusters" in choose_ingress_text
    assert "Non-prd clusters use NetBird" in choose_ingress_text
    assert (
        "Cloudflare is available only for prd clusters on Cloudflare Free." in choose_ingress_text
    )

    choose_ingress_run_text = CHOOSE_INGRESS_ROUTE_RUN_SCRIPT.read_text(encoding="utf-8")
    assert "cluster_slug" in choose_ingress_run_text
    assert "cluster_slug_lower" in choose_ingress_run_text
    assert "Base DNS domain:" in choose_ingress_run_text
    assert "public_zone_name" in choose_ingress_run_text
    assert ".public_zone_name = $public_zone_name" in choose_ingress_run_text
    assert '"dns_domain": "$dns_domain"' in choose_ingress_run_text
    assert '"public_zone_name": "$public_zone_name"' in choose_ingress_run_text
    assert (
        "Cloudflare Tunnel is only available for prd clusters on Cloudflare Free"
        in choose_ingress_run_text
    )

    assert "ingress_route: netbird" in netbird_bastion_text
    assert "zone_name" not in netbird_bastion_text
    assert "ssh_public_key" not in netbird_bastion_text
    assert "cloudflare_api_token" not in netbird_bastion_text
    assert "netbird_admin_email" not in netbird_bastion_text
    assert "Cloudflare credentials" not in netbird_bastion_text
    assert "KUBECONFIG_FILE:" in netbird_bastion_text
    assert "item: kubeconfig" in netbird_bastion_text
    create_users_text = CREATE_USERS_STEP_MANIFEST.read_text(encoding="utf-8")
    assert "id: email" in create_users_text
    assert "required: true" in create_users_text
    assert "NetBird setup" in create_users_text

    assert "cluster_dns_domain" in authentik_run_text
    assert "public_zone_name" in authentik_run_text
    assert "cluster-public-zone.sh" in authentik_run_text
    assert "https://authentik.${public_zone_name}" in authentik_run_text
    assert (
        "kubectl create namespace authentik --dry-run=client -o yaml | kubectl apply -f -"
        in authentik_run_text
    )
    assert "gitops/platform/authentik/externalsecret.yaml" in authentik_run_text
    assert "gitops/platform/authentik/ingressroute.yaml" in authentik_run_text
    assert "AUTHENTIK_POSTGRESQL__HOST" in authentik_run_text
    assert "authentik-db-pooler-rw-session.databases.svc.cluster.local" in authentik_run_text
    assert "AUTHENTIK_POSTGRESQL__PORT" in authentik_run_text
    assert "AUTHENTIK_POSTGRESQL__NAME" in authentik_run_text
    assert "AUTHENTIK_POSTGRESQL__USER" in authentik_run_text
    assert "AUTHENTIK_POSTGRESQL__USERNAME" in authentik_run_text
    assert "AUTHENTIK_POSTGRESQL__DISABLE_SERVER_SIDE_CURSORS" in authentik_run_text
    assert "AUTHENTIK_POSTGRESQL__CONN_MAX_AGE" in authentik_run_text
    assert "openbao_read_global_secret_json authentik" in authentik_run_text
    assert 'rm -f "$bootstrap_secret_file" "$authentik_secret_file"' in authentik_run_text
    assert "apply-argocd-application.sh" in authentik_run_text
    assert '--application "authentik"' in authentik_run_text
    assert "twinbox_public_zone_name" in authentik_run_text
    assert 'authentik_host="https://authentik.${public_zone_name}"' in authentik_run_text
    assert "wait_for_secret()" in authentik_run_text
    assert 'wait_for_secret "authentik-bootstrap" "Authentik bootstrap"' in authentik_run_text
    assert "Waiting for Authentik server" not in authentik_run_text
    assert "Waiting for Authentik worker" not in authentik_run_text
    assert (
        "desired=${desired_replicas}, updated=${updated_replicas}, ready=${ready_replicas}, available=${available_replicas}"
        in authentik_run_text
    )
    assert "progressing=${progressing_status}" in authentik_run_text
    assert "available=${available_status}" in authentik_run_text
    assert (
        "Could not determine Authentik host; set DNS domain in the ingress selection step"
        in authentik_run_text
    )

    headlamp_step_text = HEADLAMP_STEP_MANIFEST.read_text(encoding="utf-8")
    assert "OpenTofu" in headlamp_step_text

    pgadmin_step_text = PGADMIN_STEP_MANIFEST.read_text(encoding="utf-8")
    pgadmin_run_text = PGADMIN_STEP_SCRIPT.read_text(encoding="utf-8")
    pgadmin_server_config_text = PGADMIN_SERVER_CONFIGMAP.read_text(encoding="utf-8")
    assert "title: Install pgAdmin 4" in pgadmin_step_text
    assert "script: categories/talos-cluster/steps/install-pgadmin4/run.sh" in pgadmin_step_text
    assert "optional: true" in pgadmin_step_text
    assert "authentik-pgadmin4" in pgadmin_run_text
    assert "pgadmin4-oidc" in pgadmin_run_text
    assert "PGADMIN_OAUTH2_SERVER_METADATA_URL" in pgadmin_run_text
    assert "PGADMIN_MASTER_PASSWORD" in pgadmin_run_text
    assert "PGADMIN_DEFAULT_EMAIL" in pgadmin_run_text
    assert "Could not find a usable kubeconfig" in pgadmin_run_text
    assert "render_template()" in pgadmin_run_text
    assert (
        'pgadmin_rendered_manifest="$(mktemp "${TMPDIR:-/tmp}/pgadmin4-application-XXXXXX")"'
        in pgadmin_run_text
    )
    assert (
        "kubectl create namespace pgadmin4 --dry-run=client -o yaml | kubectl apply -f -"
        in pgadmin_run_text
    )
    assert "gitops/apps/pgadmin4.yaml" in pgadmin_run_text
    assert "gitops/platform-apps/pgadmin4/externalsecret.yaml" not in pgadmin_run_text
    assert "gitops/platform-apps/pgadmin4/configmap.yaml" not in pgadmin_run_text
    assert "gitops/platform-apps/pgadmin4/deployment.yaml" not in pgadmin_run_text
    assert "gitops/platform-apps/pgadmin4/ingressroute.yaml" not in pgadmin_run_text
    assert "wait --for=condition=Ready externalsecret/pgadmin4-oidc" not in pgadmin_run_text
    assert "Creating pgAdmin 4 database password secret" in pgadmin_run_text
    assert "pgadmin4-db-password" in pgadmin_run_text
    assert "wait_for_ready_pod pgadmin4 app.kubernetes.io/name=pgadmin4" not in pgadmin_run_text
    assert "Applying pgAdmin 4 configmap and PVC bootstrap resource" not in pgadmin_run_text
    assert "Applying pgAdmin 4 service, deployment, and ingress" not in pgadmin_run_text
    assert "Applying pgAdmin 4 Argo CD application" in pgadmin_run_text
    assert "render_template \\" in pgadmin_run_text
    assert '--manifest "$pgadmin_rendered_manifest"' in pgadmin_run_text
    assert '--application "pgadmin4"' in pgadmin_run_text
    assert '--destination-namespace "pgadmin4"' in pgadmin_run_text
    assert "kind: ConfigMap" in pgadmin_server_config_text
    assert "CloudNativePG" in pgadmin_server_config_text
    assert (
        "authentik-db-pooler-rw-session.databases.svc.cluster.local" in pgadmin_server_config_text
    )
    assert "PasswordExecCommand" in pgadmin_server_config_text
    assert "path: gitops/platform-apps/pgadmin4" in PGADMIN_APP.read_text(encoding="utf-8")
    assert "path: gitops/platform-apps/karakeep" in KARAKEEP_APP.read_text(encoding="utf-8")

    pgadmin_app_text = PLATFORM_INGRESS_APP.read_text(encoding="utf-8")
    assert "kind: ApplicationSet" in pgadmin_app_text
    assert "name: platform-ingress-set" in pgadmin_app_text
    assert "kustomize:" in pgadmin_app_text
    assert "pgadmin4-wiredoor" not in pgadmin_app_text
    assert "pgadmin4-tailscale" not in pgadmin_app_text
    assert (
        'pgadmin4.{{index .metadata.annotations "twinbox.io/public-zone-name"}}'
        not in pgadmin_app_text
    )

    headlamp_run_text = (
        REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-headlamp" / "run.sh"
    ).read_text(encoding="utf-8")
    assert "authentik-headlamp" in headlamp_run_text
    assert "authentik-auth.sh" in headlamp_run_text
    assert "authentik_ensure_token" in headlamp_run_text
    assert "HEADLAMP_CONFIG_OIDC_CLIENT_ID" in headlamp_run_text
    assert "HEADLAMP_CONFIG_OIDC_CLIENT_SECRET" in headlamp_run_text
    assert "HEADLAMP_CONFIG_OIDC_IDP_ISSUER_URL" in headlamp_run_text
    assert "HEADLAMP_CONFIG_OIDC_SCOPES" in headlamp_run_text
    assert "/oidc-callback" in headlamp_run_text
    assert "headlamp-oidc" in headlamp_run_text
    assert "sync-openbao-global-secret.sh" in headlamp_run_text
    assert "apply-argocd-application.sh" in headlamp_run_text
    assert (
        'headlamp_rendered_manifest="$(mktemp "${TMPDIR:-/tmp}/headlamp-application-XXXXXX")"'
        in headlamp_run_text
    )
    assert (
        'sed "s/__ZONE_NAME__/${public_zone_name}/g" "$headlamp_manifest_path" >"$headlamp_rendered_manifest"'
        in headlamp_run_text
    )
    assert 'dashy_redirect_uri="${dashy_host}"' in (
        REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-dashy-dashboard" / "run.sh"
    ).read_text(encoding="utf-8")
    assert "refresh-dashy-config.mjs" in (
        REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-dashy-dashboard" / "run.sh"
    ).read_text(encoding="utf-8")
    assert "--trigger-step-id install-dashy-dashboard" in (
        REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-dashy-dashboard" / "run.sh"
    ).read_text(encoding="utf-8")

    headlamp_module_text = _authentik_headlamp_module_text()
    headlamp_module_vars_text = _authentik_headlamp_module_vars_text()
    headlamp_module_outputs_text = _authentik_headlamp_module_outputs_text()
    dashy_module_providers_text = _authentik_dashy_module_providers_text()
    dashy_module_text = _authentik_dashy_module_text()
    pgadmin_module_text = _authentik_pgadmin4_module_text()
    pgadmin_module_vars_text = _authentik_pgadmin4_module_vars_text()
    pgadmin_module_outputs_text = _authentik_pgadmin4_module_outputs_text()
    pgadmin_module_providers_text = _authentik_pgadmin4_module_providers_text()
    assert 'resource "authentik_provider_oauth2" "headlamp"' in headlamp_module_text
    assert 'resource "authentik_application" "headlamp"' in headlamp_module_text
    assert "random_string" in headlamp_module_text
    assert "random_password" in headlamp_module_text
    assert "redirect_uris" in headlamp_module_text
    assert "issuer_mode" in headlamp_module_text
    assert '"per_provider"' in headlamp_module_text
    assert "application_slug" in headlamp_module_vars_text
    assert "headlamp_redirect_uri" in headlamp_module_vars_text
    assert "client_id" in headlamp_module_outputs_text
    assert "client_secret" in headlamp_module_outputs_text
    assert "issuer_url" in headlamp_module_outputs_text
    assert 'provider "authentik"' in dashy_module_providers_text
    assert "url = var.authentik_url" in dashy_module_providers_text
    assert 'trim(var.dashy_redirect_uri, "/")' in dashy_module_text
    assert 'resource "authentik_provider_oauth2" "pgadmin4"' in pgadmin_module_text
    assert 'resource "authentik_application" "pgadmin4"' in pgadmin_module_text
    assert "authentik_group" in pgadmin_module_text
    assert "authentik_policy_binding" in pgadmin_module_text
    assert "pgadmin4_redirect_uri" in pgadmin_module_vars_text
    assert "client_id" in pgadmin_module_outputs_text
    assert "client_secret" in pgadmin_module_outputs_text
    assert "issuer_url" in pgadmin_module_outputs_text
    assert "redirect_uri" in pgadmin_module_outputs_text
    assert 'provider "authentik"' in pgadmin_module_providers_text
    assert "url = var.authentik_url" in pgadmin_module_providers_text

    headlamp_external_secret_text = _headlamp_oidc_externalsecret_text()
    assert "kind: ExternalSecret" in headlamp_external_secret_text
    assert "headlamp-oidc" in headlamp_external_secret_text
    assert "HEADLAMP_CONFIG_OIDC_CLIENT_ID" in headlamp_external_secret_text
    assert "HEADLAMP_CONFIG_OIDC_CLIENT_SECRET" in headlamp_external_secret_text
    assert "HEADLAMP_CONFIG_OIDC_IDP_ISSUER_URL" in headlamp_external_secret_text
    assert "HEADLAMP_CONFIG_OIDC_SCOPES" in headlamp_external_secret_text
    pgadmin_external_secret_text = PGADMIN_EXTERNALSECRET.read_text(encoding="utf-8")
    pgadmin_server_config_text = PGADMIN_SERVER_CONFIGMAP.read_text(encoding="utf-8")
    assert "kind: ExternalSecret" in pgadmin_external_secret_text
    assert "pgadmin4-oidc" in pgadmin_external_secret_text
    assert "PGADMIN_DEFAULT_EMAIL" in pgadmin_external_secret_text
    assert "PGADMIN_DEFAULT_PASSWORD" in pgadmin_external_secret_text
    assert "PGADMIN_MASTER_PASSWORD" in pgadmin_external_secret_text
    assert "PGADMIN_OAUTH2_CLIENT_ID" in pgadmin_external_secret_text
    assert "PGADMIN_OAUTH2_CLIENT_SECRET" in pgadmin_external_secret_text
    assert "PGADMIN_OAUTH2_SERVER_METADATA_URL" in pgadmin_external_secret_text
    assert "PGADMIN_OAUTH2_SCOPE" in pgadmin_external_secret_text
    assert "kind: ConfigMap" in pgadmin_server_config_text
    assert "CloudNativePG" in pgadmin_server_config_text
    assert (
        "authentik-db-pooler-rw-session.databases.svc.cluster.local" in pgadmin_server_config_text
    )
    assert "PasswordExecCommand" in pgadmin_server_config_text
    pgadmin_deployment_text = PGADMIN_DEPLOYMENT.read_text(encoding="utf-8")
    assert "pgadmin4-db-password" in pgadmin_deployment_text
    assert "name: pgadmin4-bootstrap" in pgadmin_deployment_text
    assert "name: pgadmin4-db-password" in pgadmin_deployment_text
    assert "pgadmin4-servers" in pgadmin_deployment_text
    assert "postStart" in pgadmin_deployment_text
    assert "load-servers" in pgadmin_deployment_text
    assert "ENABLE_SERVER_PASS_EXEC_CMD = True" in pgadmin_deployment_text
    assert "pgAdmin shared server passexec patch applied" in pgadmin_deployment_text
    assert "passexec_cmd=data.passexec_cmd" in pgadmin_deployment_text
    assert "passexec_expiration=data.passexec_expiration" in pgadmin_deployment_text
    assert "update sharedserver" in pgadmin_deployment_text
    assert "server.id = sharedserver.osid" in pgadmin_deployment_text
    assert "pgAdmin owner servers with password exec commands:" in pgadmin_deployment_text
    assert "pgAdmin shared server password exec rows repaired:" in pgadmin_deployment_text
    assert "print(os.environ" not in pgadmin_deployment_text
    assert "server where shared = 1 limit 1" in pgadmin_deployment_text
    assert "startupProbe" in pgadmin_deployment_text
    assert "failureThreshold: 36" in pgadmin_deployment_text
    assert "exec:" in pgadmin_deployment_text
    assert "server where shared = 1 limit 1" in pgadmin_deployment_text
    assert "runAsNonRoot: true" in pgadmin_deployment_text
    assert "runAsUser: 5050" in pgadmin_deployment_text
    assert "runAsGroup: 0" in pgadmin_deployment_text
    assert "runAsUser: 65534" in pgadmin_deployment_text
    assert "runAsGroup: 65534" in pgadmin_deployment_text
    assert "fsGroup: 0" in pgadmin_deployment_text
    assert "PGADMIN_DISABLE_POSTFIX" in pgadmin_deployment_text
    assert "PYTHONPATH" in pgadmin_deployment_text
    assert "LOG_FILE = '/dev/null'" in pgadmin_deployment_text
    assert "allowPrivilegeEscalation: false" in pgadmin_deployment_text
    assert "type: RuntimeDefault" in pgadmin_deployment_text
    assert "drop:" in pgadmin_deployment_text
    assert "- ALL" in pgadmin_deployment_text
    assert "cd /pgadmin4" in pgadmin_deployment_text
    assert '--timeout "${GUNICORN_TIMEOUT:-86400}"' in pgadmin_deployment_text

    cloudflare_tunnel_run_text = (
        REPO_ROOT
        / "categories"
        / "talos-cluster"
        / "steps"
        / "configure-cloudflare-tunnel"
        / "run.sh"
    ).read_text(encoding="utf-8")
    assert (
        'curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${cf_account_id}/cfd_tunnel/${cf_tunnel_id}/token"'
        in cloudflare_tunnel_run_text
    )
    assert "jq -r '.success // false'" in cloudflare_tunnel_run_text
    assert "jq -r '.result // empty'" in cloudflare_tunnel_run_text
    assert "cluster_dns_domain" in cloudflare_tunnel_run_text
    assert "cluster-public-zone.sh" in cloudflare_tunnel_run_text
    assert "twinbox_public_zone_name" in cloudflare_tunnel_run_text
    assert "twinbox_cluster_dns_zone_name" in cloudflare_tunnel_run_text
    assert "cluster_slug_lower" in cloudflare_tunnel_run_text
    assert (
        "Cloudflare Tunnel is only available for prd clusters on Cloudflare Free"
        in cloudflare_tunnel_run_text
    )
    assert (
        "Using the provided Cloudflare token for DNS record creation" in cloudflare_tunnel_run_text
    )
    assert "DNS zone name: $cloudflare_dns_zone_name" in cloudflare_tunnel_run_text
    assert (
        "echo \"[$(date '+%Y-%m-%d %H:%M:%S')] Public zone name: $public_zone_name\""
        in cloudflare_tunnel_run_text
    )
    assert "Preflighting Cloudflare zone" in cloudflare_tunnel_run_text
    assert (
        'curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${cf_zone_id}"'
        in cloudflare_tunnel_run_text
    )
    assert "Cloudflare sees zone name: $cloudflare_zone_name" in cloudflare_tunnel_run_text
    assert (
        "resolves to ${cloudflare_zone_name}, but the wizard selected ${cloudflare_dns_zone_name}"
        in cloudflare_tunnel_run_text
    )
    assert "continuing without a zone-name preflight" in cloudflare_tunnel_run_text
    assert 'dns_record_name="*.${public_zone_name}"' in cloudflare_tunnel_run_text
    assert "Creating DNSEndpoint for tunnel CNAME" in cloudflare_tunnel_run_text
    assert "cloudflare-tunnel-dns" in cloudflare_tunnel_run_text
    assert "already have a tunnel with this name" in cloudflare_tunnel_run_text
    assert ".result.Token" not in cloudflare_tunnel_run_text
    assert "cluster-hostnames" in cloudflare_tunnel_run_text
    assert "Rendered cloudflare-tunnel application to" in cloudflare_tunnel_run_text
    assert "helm:" in cloudflare_tunnel_run_text
    assert "cloudflare-tunnel-remote" in cloudflare_tunnel_run_text
    assert "tunnel_token" in cloudflare_tunnel_run_text
    assert "platform-ingress.yaml" in cloudflare_tunnel_run_text
    assert "upsert-argocd-cluster-secret.sh" in cloudflare_tunnel_run_text
    assert "DNSEndpoint for tunnel CNAME" in cloudflare_tunnel_run_text
    assert "argocd-server" in cloudflare_tunnel_run_text
    assert "Argo CD server not ready yet (attempt ${i}/30)" in cloudflare_tunnel_run_text
    assert (
        "Timed out waiting for the Argo CD server deployment to become ready"
        in cloudflare_tunnel_run_text
    )
    assert cloudflare_tunnel_run_text.index(
        "platform-ingress.yaml"
    ) < cloudflare_tunnel_run_text.index("Applying cloudflare-tunnel application")

    assert "Cloudflare Tunnel is **prd-only** on Cloudflare Free" in INGRESS_POLICY_DOC.read_text(
        encoding="utf-8"
    )

    netbird_bastion_run_text = NETBIRD_BASTION_STEP_SCRIPT.read_text(encoding="utf-8")
    assert "cluster-public-zone.sh" in netbird_bastion_run_text
    assert "twinbox_public_zone_name" in netbird_bastion_run_text
    assert (
        "DNS domain not found. Please run Configure DNS Provider before provisioning NetBird."
        in (netbird_bastion_run_text)
    )
    assert "Creating NetBird DNS records through external-dns" in netbird_bastion_run_text
    assert "kind: DNSEndpoint" in netbird_bastion_run_text
    assert "netbird-bastion-dns" in netbird_bastion_run_text
    assert "dnsName: ${netbird_fqdn}" in netbird_bastion_run_text
    # Proxy subdomain record was removed; proxy domain is now the zone itself
    assert (
        "netbird-bastion-dns" not in netbird_bastion_run_text
        or "proxy." not in netbird_bastion_run_text
    )
    assert '-var "public_zone_name=$public_zone_name"' in netbird_bastion_run_text
    assert "external-dns" in netbird_bastion_run_text
    assert "check-bastion-public-reachability.py" in netbird_bastion_run_text
    assert 'wait_for_bastion_public_dns_records "$public_ipv4" "$netbird_fqdn"' in (
        netbird_bastion_run_text
    )
    assert 'wait_for_bastion_public_dns_records "$server_ipv4" "$netbird_fqdn"' in (
        netbird_bastion_run_text
    )
    assert "command -v ssh >/dev/null" in netbird_bastion_run_text
    assert "command -v ssh-keygen >/dev/null" in netbird_bastion_run_text
    assert "command -v python3 >/dev/null" in netbird_bastion_run_text
    assert "command -v scp >/dev/null" in netbird_bastion_run_text
    assert "OpenSSH client tools are available" in netbird_bastion_run_text
    assert 'bastion_provider="$(printf' in netbird_bastion_run_text
    assert "provision_existing_bastion()" in netbird_bastion_run_text
    assert "render-netbird-bastion-bootstrap.py" in netbird_bastion_run_text
    assert "netbird-bastion-bootstrap-template.sh" in netbird_bastion_run_text
    assert "existing_bastion_public_ipv4 is required for existing-vm" in netbird_bastion_run_text
    assert "existing_bastion_confirm_clean_host=true" in netbird_bastion_run_text
    assert "BASTION_PROVIDER" in netbird_bastion_run_text
    assert "BASTION_PUBLIC_IPV4" in netbird_bastion_run_text
    assert "BASTION_SSH_HOST" in netbird_bastion_run_text
    assert 'server_name="twinbox-${cluster_id}-netbird"' in netbird_bastion_run_text
    assert "NetBird Hetzner resource prefix" in netbird_bastion_run_text
    # The step result includes cluster_id and secrets_path (netbird_proxy_domain was removed)
    assert "cluster_id: $cluster_id," in netbird_bastion_run_text
    assert "urllib.error.HTTPError" in netbird_bastion_run_text
    assert "time.sleep(3)" in netbird_bastion_run_text
    assert 'delete_hcloud_resources_by_name "servers" "$legacy_server_name" "$server_name"' in (
        netbird_bastion_run_text
    )
    assert (
        'delete_hcloud_resources_by_name "ssh_keys" "${legacy_server_name}-ssh-key" '
        '"${server_name}-ssh-key"' in netbird_bastion_run_text
    )
    assert "tofu init -no-color -input=false" in netbird_bastion_run_text
    assert "tofu apply -no-color -auto-approve -input=false" in netbird_bastion_run_text
    assert "read_first_admin_email()" in netbird_bastion_run_text
    assert "create-users-and-groups.json" in netbird_bastion_run_text
    assert (
        "First admin email is required. Please run Create Users and Groups before provisioning NetBird."
        in (netbird_bastion_run_text)
    )
    assert "ssh-keygen -t ed25519" in netbird_bastion_run_text
    assert "NETBIRD_ADMIN_TOKEN" in netbird_bastion_run_text
    assert "NETBIRD_SETUP_TOKEN" in netbird_bastion_run_text
    assert "manual NetBird API token" not in netbird_bastion_run_text
    assert "NetBird automated setup did not produce a Personal Access Token in time" in (
        netbird_bastion_run_text
    )
    assert "/var/log/cloud-init-output.log" in netbird_bastion_run_text
    assert 'bastion_cloud_init_log_path="/var/log/cloud-init-output.log"' in (
        netbird_bastion_run_text
    )
    assert "redact_bastion_cloud_init_log()" in netbird_bastion_run_text
    assert "personal_access_token" in netbird_bastion_run_text
    assert "TOKEN|PASSWORD|SECRET|PRIVATE_KEY" in netbird_bastion_run_text
    assert "emit_bastion_cloud_init_tail 80" in netbird_bastion_run_text
    assert "emit_bastion_cloud_init_tail 120" in netbird_bastion_run_text
    assert "emit_new_bastion_cloud_init_lines" in netbird_bastion_run_text
    assert "Streaming bastion cloud-init output while waiting for setup token" in (
        netbird_bastion_run_text
    )
    assert "[bastion cloud-init] %s" in netbird_bastion_run_text
    assert "No new bastion cloud-init output yet; waiting for setup token" in (
        netbird_bastion_run_text
    )
    assert "Last bastion cloud-init output before timeout" in netbird_bastion_run_text
    assert "Waiting for NetBird setup (attempt ${i}/60)" not in netbird_bastion_run_text
    assert "No NetBird setup token found after bastion bootstrap" in netbird_bastion_run_text
    assert "cloudflare-netbird" not in netbird_bastion_run_text
    assert "api.cloudflare.com/client/v4/zones" not in netbird_bastion_run_text
    assert "cloudflare_api_token" not in netbird_bastion_run_text

    assert "script: categories/talos-cluster/steps/install-headlamp/run.sh" in headlamp_text

    assert "script: categories/talos-cluster/steps/install-grafana/run.sh" in grafana_text
    assert "--no-wait" not in (
        REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-grafana" / "run.sh"
    ).read_text(encoding="utf-8")
    assert "script: categories/talos-cluster/steps/install-prometheus/run.sh" in prometheus_text
    assert "script: categories/talos-cluster/steps/install-prometheus/run.sh" in prometheus_text
    assert "url: http://tempo.monitoring.svc.cluster.local:3200" in (
        GRAFANA_VALUES.read_text(encoding="utf-8")
    )
    assert "http://tempo.monitoring.svc.cluster.local:3200/ready" in (
        REPO_ROOT / "scripts" / "manager" / "diagnose-monitoring.sh"
    ).read_text(encoding="utf-8")
    assert "port-forward svc/tempo 3200:3200" in (
        REPO_ROOT / "scripts" / "manager" / "diagnose-monitoring.sh"
    ).read_text(encoding="utf-8")


def test_netbird_cloud_init_escapes_shell_variables_for_templatefile():
    text = (
        REPO_ROOT / "infra" / "opentofu" / "netbird" / "cloud-init" / "netbird.yaml.tftpl"
    ).read_text(encoding="utf-8")
    bootstrap_text = NETBIRD_BASTION_BOOTSTRAP_TEMPLATE.read_text(encoding="utf-8")

    assert "#cloud-config" in text
    assert "package_update: true" in text
    assert "  - python3-yaml" in text
    assert "  - ufw" in text
    assert "write_files" in text
    assert "bootstrap-netbird.sh" in text
    assert "/root/bootstrap-netbird.sh" in text
    assert "netbird_bootstrap_script" in text
    assert "/opt/netbird/.bootstrap.env" in text
    assert "ufw --force enable" in text
    assert "$${" not in text, "template should not contain $$ escapes"
    assert "${dns_env[@]}" not in text, "bash arrays must not be Terraform template expressions"
    assert "[@" not in text, "bash array expansions are invalid Terraform template expressions"
    assert "${NETBIRD_VERSION}" not in text, "bash var NETBIRD_VERSION must use $VAR not ${VAR}"
    assert "${volume_dir}" not in text, "bash vars must not be Terraform template expressions"
    assert '"$NETBIRD_URL' in bootstrap_text or "'$NETBIRD_URL" in bootstrap_text
    assert 'BOOTSTRAP_NETBIRD_URL="http://$NETBIRD_SERVER_IP"' in bootstrap_text
    assert (
        "docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}'"
        in bootstrap_text
    )
    assert "/opt/netbird/.twinbox-bastion.json" in bootstrap_text
    assert "Refusing to overwrite an unmanaged NetBird installation" in bootstrap_text


def test_netbird_bastion_bootstrap_renderer_contract():
    renderer_text = NETBIRD_BASTION_BOOTSTRAP_RENDERER.read_text(encoding="utf-8")
    bootstrap_text = NETBIRD_BASTION_BOOTSTRAP_TEMPLATE.read_text(encoding="utf-8")

    assert "--netbird-fqdn" in renderer_text
    assert "--dns-api-token" in renderer_text
    assert "bootstrap.env" in renderer_text
    assert "dns-credentials" in renderer_text
    assert "print(" not in renderer_text
    assert "BOOTSTRAP_ENV" in bootstrap_text
    assert "DNS_CREDENTIALS_FILE" in bootstrap_text
    assert '-H "Host: $NETBIRD_DOMAIN"' in bootstrap_text
    assert '"$BOOTSTRAP_NETBIRD_URL/oauth2/.well-known/openid-configuration"' in bootstrap_text
    assert "Reusing existing NetBird setup result with personal access token." in bootstrap_text
    assert bootstrap_text.index(
        "Reusing existing NetBird setup result with personal access token."
    ) < bootstrap_text.index('curl -fsS -X POST "$BOOTSTRAP_NETBIRD_URL/api/setup"')
    assert 'curl -fsS -X POST "$BOOTSTRAP_NETBIRD_URL/api/setup"' in bootstrap_text
    assert 'curl -fsS -X POST "$NETBIRD_URL/api/setup"' not in bootstrap_text
    assert "Checking public NetBird TLS endpoint" in bootstrap_text
    assert "Public NetBird TLS endpoint is ready" in bootstrap_text
    assert (
        "NetBird setup completed, but public TLS is not trusted or reachable yet" in bootstrap_text
    )
    assert "netbird-automated-setup.sh" not in bootstrap_text
    assert "PUBLIC_ZONE_NAME" in bootstrap_text
    assert "seed_netbird_account_domain()" in bootstrap_text
    assert '"twinbox.internal"' in bootstrap_text
    assert "private peer DNS domain" in bootstrap_text
    assert "public_zone_name, setup_result = sys.argv" not in bootstrap_text
    assert "settings_extra_user_approval_required = 0" in bootstrap_text
    assert "domain_category = ?, is_domain_primary_account = 1" in bootstrap_text
    assert "retry_netbird_step()" in bootstrap_text
    assert "local max_attempts=8" in bootstrap_text
    assert (
        'retry_netbird_step "Start NetBird reverse proxy" $DOCKER_COMPOSE_COMMAND up -d proxy'
        in (bootstrap_text)
    )
    assert (
        'raise SystemExit("ERROR: Could not patch NetBird reverse proxy startup for retries.")'
        in (bootstrap_text)
    )
    assert 'retry_netbird_step "Pull NetBird compose images" docker compose pull' in bootstrap_text
    assert "docker compose pull || true" not in bootstrap_text


def test_netbird_ingress_uses_netbird_proxy_before_idp_registration():
    text = NETBIRD_INGRESS_STEP_SCRIPT.read_text(encoding="utf-8")
    main_text = AUTHENTIK_NETBIRD_MODULE_MAIN.read_text(encoding="utf-8")
    vars_text = AUTHENTIK_NETBIRD_MODULE_VARS.read_text(encoding="utf-8")
    providers_text = AUTHENTIK_NETBIRD_MODULE_PROVIDERS.read_text(encoding="utf-8")
    outputs_text = AUTHENTIK_NETBIRD_MODULE_OUTPUTS.read_text(encoding="utf-8")

    assert "authentik_setup_forward" in text
    assert 'authentik_api_url="${AUTHENTIK_API_BASE%/api/v3}"' in text
    assert '-var "authentik_api_url=$authentik_api_url"' in text
    assert '-var "authentik_public_url=$authentik_public_url"' in text
    assert "read_first_admin_email()" in text
    assert "authentik_user_uid_by_email()" in text
    assert "seed_netbird_account_for_sso()" in text
    assert 'identity_provider_id="$(tofu output -raw -no-color identity_provider_id)"' in text
    assert 'seed_netbird_account_for_sso "$identity_provider_id" "$netbird_admin_email"' in text
    assert "ensure_authentik_netbird_grant_types()" in text
    assert 'netbird_oidc_provider_pk="$(tofu output -raw -no-color provider_pk)"' in text
    assert 'ensure_authentik_netbird_grant_types "$netbird_oidc_provider_pk"' in text
    assert '"grant_types":["authorization_code","refresh_token"]' in text
    assert 'glob.glob("/var/lib/docker/volumes/*/_data/store.db")' in text
    assert "Failed to seed NetBird account domain and SSO owner context" in text
    assert "settings_extra_user_approval_required = 0" in text
    assert 'base64.b64encode(raw).decode().rstrip("=")' in text
    assert "netbird_host_resource_address()" in text
    assert "resolve_traefik_cluster_ip()" in text
    assert "read_service_cidrs_json()" in text
    assert "read_pod_cidrs_json()" in text
    assert "read_management_lan_cidrs_json()" in text
    assert "read_json_string_array_input()" in text
    assert "ipv4_in_cidrs_json()" in text
    assert "normalize_traefik_resource_address()" in text
    assert "ensure_netbird_proxy_peer()" in text
    assert "discover_netbird_proxy_peer_ip()" in text
    assert "persist_netbird_proxy_peer_ip()" in text
    assert "ensure_netbird_bastion_exit_peer()" in text
    assert "wait_for_netbird_proxy_backend()" in text
    assert (
        'traefik_network_resource_address="$(netbird_host_resource_address "$traefik_resource_address")"'
        in text
    )
    assert (
        'traefik_resource_address="$(normalize_traefik_resource_address "$traefik_resource_address")"'
        in text
    )
    assert "Resolving ${requested_address} to ClusterIP via kubectl" in text
    assert "Empty Traefik address; using Traefik ClusterIP" in text
    assert 'traefik_target_port="8082"' in text
    assert 'traefik_target_protocol="http"' in text
    assert 'service_cidrs_json="$(read_service_cidrs_json)"' in text
    assert 'pod_cidrs_json="$(read_pod_cidrs_json)"' in text
    assert 'management_lan_cidrs_json="$(read_management_lan_cidrs_json "$cluster_json")"' in text
    assert '-var "traefik_resource_address=$traefik_network_resource_address"' in text
    assert '-var "pod_cidrs=${pod_cidrs_json}"' in text
    assert '-var "management_lan_cidrs=${management_lan_cidrs_json}"' in text
    # The services block was removed; traefik_resource_address is now only passed to the network module
    assert "netbird-proxy-services-" not in text
    assert 'traefik_resource_address="traefik.traefik.svc.cluster.local"' not in text
    assert "kubectl -n traefik get svc traefik -o jsonpath" in text
    assert "TRAEFIK_NETWORK_RESOURCE_ADDRESS" in text
    assert "TRAEFIK_TARGET_PORT" in text
    assert "TRAEFIK_TARGET_PROTOCOL" in text
    assert "POD_CIDRS" in text
    assert "MANAGEMENT_LAN_CIDRS" in text
    assert "ADGUARD_DNS_GROUP_ID" in text
    assert "MANAGEMENT_LAN_ROUTERS_GROUP_ID" in text
    assert "BASTION_EXIT_ROUTERS_GROUP_ID" in text
    assert "BROWSER_SSH_GROUP_ID" in text
    assert "EXIT_NODE_USERS_GROUP_ID" in text
    assert "proxy_setup_key" in text
    assert "netbird-proxy-access" in text
    assert "management_lan_router_setup_key" in text
    assert "bastion_exit_router_setup_key" in text
    assert "browser_ssh_setup_key" in text
    assert "netbird-management-lan-router" in text
    assert "netbird-bastion-exit-router" in text
    assert "netbird-browser-ssh" in text
    assert "NETBIRD_PRIVATE_IP" in text
    assert "netbirdio/netbird:${PINNED_NETBIRD_VERSION:-0.73.2}" in text
    assert "docker run -d" in text and "--name netbird-client" in text
    assert "--name netbird-hetzner-exit" in text
    assert "twinbox-${cluster_id}-hetzner-exit" in text
    assert "/var/lib/netbird-hetzner-exit:/var/lib/netbird" in text
    assert "--sysctl net.ipv4.ip_forward=1" in text
    exit_peer_block = re.search(
        r"docker run -d \\\n  --name netbird-hetzner-exit(.*?)netbird status --check ready",
        text,
        flags=re.DOTALL,
    )
    assert exit_peer_block
    assert "--network host" not in exit_peer_block.group(1)
    assert "NB_INTERFACE_NAME=wt1" in text
    assert "NB_WIREGUARD_PORT=51821" in text
    assert "NB_NFTABLES_TABLE=netbird_exit" in text
    assert "NB_DISABLE_IPV6=true" in text
    assert "disable_netbird_account_ipv6_overlay" in text
    assert '"Authorization": f"Token {token}"' in text
    assert '"ipv6_enabled_groups": []' in text
    assert "node_prefix_length" in text
    assert 'emit(f"{management_ip}/{prefix_length}")' in text
    assert 'emit(f"{gateway_ip}/{prefix_length}")' in text
    assert "authentik_resolve_scope_mapping_id" in text
    assert '-var "property_mapping_ids=$property_mapping_ids_json"' in text
    assert '-var "authentik_url=$authentik_url"' not in text
    assert "api.cloudflare.com/client/v4" not in text
    assert "cloudflare-tunnel-dns" in text  # cleanup of stale tunnel record
    # Network secret is now written (was removed when services block was removed)
    assert "Writing network secret for helper scripts" in text
    assert "authentik_property_mapping_provider_scope" not in main_text
    assert "property_mappings          = var.property_mapping_ids" in main_text
    assert 'variable "authentik_api_url"' in vars_text
    assert 'variable "authentik_public_url"' in vars_text
    assert 'variable "property_mapping_ids"' in vars_text
    assert "url = var.authentik_api_url" in providers_text
    assert 'trim(var.authentik_public_url, "/")' in outputs_text
    assert 'output "provider_pk"' in outputs_text

    assert 'name: "authentik", domain: $authentik_domain, path: "/"' in text
    assert "netbird-wildcard-dns" in text
    assert "check-bastion-public-reachability.py" in text
    assert 'wait_for_bastion_public_dns_records "$netbird_proxy_ip"' in text
    assert "twinbox-wildcard-check.${public_zone_name}" in text
    assert "netbird-dns-zone.py" in text
    assert '--zone-domain "$public_zone_name"' in text
    assert '--group-id "$admins_group_id"' in text
    assert '--group-id "$management_vm_group_id"' in text
    assert '--group-id "$adguard_dns_group_id"' in text
    assert '--group-id "$exit_node_users_group_id"' in text
    assert '--record "${public_zone_name}=${netbird_proxy_ip}"' in text
    assert '--record "*.${public_zone_name}=${netbird_proxy_ip}"' in text
    assert "NETBIRD_IP" in text
    assert "BASTION_PUBLIC_IPV4" in text
    assert "BASTION_SSH_HOST" in text
    assert "BASTION_SSH_PORT" in text
    assert "BASTION_SSH_USER" in text
    assert "NETBIRD_PROXY_DOMAIN" in text
    assert 'TWINBOX_NETBIRD_TOKEN="$netbird_token"' in text
    assert 'TWINBOX_NETBIRD_URL="$netbird_management_url"' in text
    assert 'TWINBOX_NETBIRD_BASTION_SECRET="$netbird_bastion_secret"' in text
    assert 'CLUSTER_ID="$cluster_id"' in text
    # The services block was removed; netbird_proxy_domain is no longer passed to tofu
    assert "wait_for_netbird_routing_peer" in text
    assert "wait_for_traefik_reverse_proxy_backend" in text
    assert "kubernetes.io/service-name=traefik" in text
    assert "kubernetes.io/service-name=traefik-netbird" in text
    assert "wait_for_public_oidc_discovery" in text
    assert "wait_for_public_oidc_authorize" in text
    assert "verify_public_oidc_authorize" in text
    assert 'verify_public_oidc_authorize "$authentik_base_url" "$client_id" "$redirect_uri"' in text
    assert (
        'wait_for_public_oidc_authorize "$authentik_public_url" "$netbird_oidc_client_id"' in text
    )
    assert "Public Authentik authorize endpoint not ready yet" in text
    assert 'curl -fsS --connect-timeout 5 --max-time 15 "$discovery_url"' in text
    assert "Continuing NetBird configuration; browser SSO will be healthy once public TLS" in text
    assert "apply_netbird_identity_provider_with_retry()" in text
    assert 'mktemp "${TMPDIR:-/tmp}/netbird-idp-apply-XXXXXX"' in text
    assert "identity provider issuer is unreachable|no such host" in text
    assert "NetBird identity provider issuer validation is not ready yet" in text
    assert "NetBird identity provider issuer validation did not become ready" in text
    assert (
        'fail "Public Authentik OIDC discovery did not become reachable through NetBird proxy'
        not in text
    )

    auth_setup_index = text.index("Configuring Authentik OIDC application for NetBird")
    network_index = text.index("Creating NetBird groups, routing resources, and setup keys")
    routing_peer_index = text.index("Deploying NetBird routing peers before enabling reverse proxy")
    backend_index = text.index('wait_for_traefik_reverse_proxy_backend "$traefik_resource_address"')
    proxy_peer_index = text.index('ensure_netbird_proxy_peer "$proxy_setup_key"')
    alias_index = text.index('ensure_bastion_traefik_netbird_alias "$netbird_domain"')
    bastion_ip_index = text.index('bastion_netbird_ip="$(discover_netbird_proxy_peer_ip)"')
    exit_peer_index = text.index(
        'ensure_netbird_bastion_exit_peer "$bastion_exit_router_setup_key"'
    )
    proxy_backend_index = text.index("wait_for_netbird_proxy_backend \\")
    network_secret_index = text.index("Writing network secret for helper scripts")
    service_cidrs_index = text.index('service_cidrs_json="$(read_service_cidrs_json)"')
    pod_cidrs_index = text.index('pod_cidrs_json="$(read_pod_cidrs_json)"')
    management_lan_index = text.index('management_lan_cidrs_json="$(read_management_lan_cidrs_json')
    normalize_traefik_index = text.index(
        'traefik_resource_address="$(normalize_traefik_resource_address'
    )
    dns_index = text.index("Creating wildcard DNS record for NetBird proxy")
    discovery_index = text.index('wait_for_public_oidc_discovery "$netbird_oidc_issuer"')
    authentik_service_index = text.index("Creating NetBird reverse proxy service for Authentik")
    netbird_service_index = text.index(
        "Creating NetBird reverse proxy service for NetBird coalescing fallback"
    )
    idp_index = text.index("Registering Authentik as NetBird identity provider")
    idp_dns_index = text.rindex('wait_for_oidc_issuer_dns "$netbird_oidc_issuer"')
    idp_apply_index = text.rindex("apply_netbird_identity_provider_with_retry")

    # The services block was removed; services are now created per-app by ensure-netbird-service.sh
    assert "Creating NetBird reverse proxy services" not in text or text.index(
        "Creating NetBird reverse proxy services"
    ) > text.index("Writing network secret for helper scripts")
    assert (
        "wait_for_netbird_routing_peer" in text and "wait_forward_netbird_routing_peer" not in text
    )
    assert "netbird-proxy-services-" not in text or text.index(
        "netbird-proxy-services-"
    ) > text.index("Writing network secret for helper scripts")
    # network secret is written before routing peers, service creation, and the OIDC flow.
    assert (
        service_cidrs_index
        < pod_cidrs_index
        < management_lan_index
        < normalize_traefik_index
        < auth_setup_index
    )
    assert (
        auth_setup_index
        < network_index
        < network_secret_index
        < routing_peer_index
        < backend_index
        < proxy_peer_index
        < alias_index
        < bastion_ip_index
        < exit_peer_index
        < proxy_backend_index
        < dns_index
        < authentik_service_index
        < netbird_service_index
        < discovery_index
        < idp_index
        < idp_dns_index
        < idp_apply_index
    )
    assert 'netbird_domain="netbird.${public_zone_name}"' in text
    assert "patch-netbird-traefik-alias.py" in text
    assert 'docker compose "${compose_args[@]}" ps -q "$service_name"' in text
    assert 'docker compose ps -q "$service_name"' in text
    assert "verify_netbird_proxy_alias()" in text
    assert "docker inspect -f '{{.Id}}'" in text
    assert "getent hosts" not in text
    assert "10.96.0.0/12" not in text
    assert "10.244.0.0/16" not in text
    assert "--target-type cluster" in text
    assert '--target-id "$netbird_domain"' in text
    assert '--target-host "$netbird_domain"' in text
    assert "--target-port 443" in text
    assert "--target-protocol https" in text
    assert "--target-direct-upstream true" in text
    assert "--target-skip-tls-verify false" in text


def test_ensure_netbird_service_uses_current_api_and_safe_skips():
    text = ENSURE_NETBIRD_SERVICE_SCRIPT.read_text(encoding="utf-8")

    assert 'NETBIRD_REVERSE_PROXY_API="${NETBIRD_URL%/}/api/reverse-proxies"' in text
    assert "/api/reverse-proxy/" not in text
    assert '"${NETBIRD_REVERSE_PROXY_API}/clusters"' in text
    assert '"${NETBIRD_REVERSE_PROXY_API}/domains"' in text
    assert '"${NETBIRD_REVERSE_PROXY_API}/services"' in text
    assert "Authorization: Token ${NETBIRD_TOKEN}" in text
    assert "Authorization: Bearer ${NETBIRD_TOKEN}" not in text
    assert '"${NETBIRD_REVERSE_PROXY_API}/domains/"' not in text
    assert '"${NETBIRD_REVERSE_PROXY_API}/services/"' not in text
    assert "normalize_netbird_collection" in text
    assert "--normalize-collection" in text
    assert "--target-type" in text
    assert "--target-id" in text
    assert "--target-host" in text
    assert "--target-port" in text
    assert "--target-protocol" in text
    assert "--target-direct-upstream" in text
    assert "--target-skip-tls-verify" in text
    assert 'elif (.clusters | type) == "array" then .clusters' in text
    assert 'elif (.results | type) == "array" then .results' in text
    assert 'elif (.items | type) == "array" then .items' in text
    assert 'elif (.resources | type) == "array" then .resources' in text
    assert "NetBird network secret not ready; skipping service creation" in text
    assert "NetBird network secret does not contain TRAEFIK_RESOURCE_ADDRESS" in text
    assert 'NETBIRD_TOKEN="${TWINBOX_NETBIRD_TOKEN:-${NETBIRD_ADMIN_TOKEN:-' in text
    assert '${NETBIRD_API_TOKEN:-${NETBIRD_TOKEN:-}}}}"' in text
    assert ".NETBIRD_ADMIN_TOKEN // .NETBIRD_API_TOKEN // .NETBIRD_SETUP_TOKEN" in text
    assert 'NETBIRD_URL="${TWINBOX_NETBIRD_URL:-${NETBIRD_URL:-}}"' in text
    assert "! -name 'netbird-bastion-exit-router-*.json'" in text
    assert "No NetBird proxy domain found" in text
    assert "Could not find TRAEFIK_RESOURCE_ID; service creation may fail" not in text
    assert "No NetBird reverse proxy cluster found" in text
    assert "NetBird domain creation returned HTTP" in text
    assert "NetBird service lookup failed for" in text
    assert "response was not JSON for" in text
    assert "fail_netbird()" in text
    assert "Could not query NetBird reverse proxy clusters" in text
    assert "Could not query NetBird reverse proxy services" in text
    assert "NetBird POST returned HTTP" in text
    assert "NetBird PUT returned HTTP" in text
    assert "NetBird POST returned HTTP ${http_status:-<empty>}; skipping" not in text
    assert "NetBird PUT returned HTTP ${http_status:-<empty>}; skipping" not in text
    assert "already targets ${existing_target_cluster}, expected ${NETBIRD_PROXY_DOMAIN}" in text
    assert "live cluster resources endpoint" in text
    assert "Could not find Traefik resource ${TRAEFIK_RESOURCE_ADDRESS}" not in text
    assert "--argjson service_enabled" in text
    assert "--argjson target_port" in text
    assert "--argjson direct_upstream" in text
    assert "--argjson skip_tls_verify" in text
    assert "--arg protocol" in text
    assert "--argjson enabled" not in text
    assert "TARGET_ID_OVERRIDE" in text
    assert "TARGET_TYPE_OVERRIDE" in text
    assert "TARGET_HOST_OVERRIDE" in text
    assert "TARGET_DIRECT_UPSTREAM" in text
    assert "TARGET_SKIP_TLS_VERIFY" in text
    assert "TRAEFIK_TARGET_PORT" in text
    assert "TRAEFIK_TARGET_PROTOCOL" in text
    assert '.TRAEFIK_TARGET_PORT // "443"' in text
    assert ".TRAEFIK_TARGET_PROTOCOL // empty" in text
    assert "target_id: $target_id" in text
    assert "target_type: $target_type" in text
    assert "host: $host" in text
    assert "port: $target_port" in text
    assert "port: 443" not in text
    assert "protocol: $protocol" in text
    assert "direct_upstream: $direct_upstream" in text
    assert "skip_tls_verify: $skip_tls_verify" in text
    assert 'TRAEFIK_TARGET_PROTOCOL="http"' in text


def normalize_netbird_collection(payload, field):
    result = subprocess.run(
        ["bash", str(ENSURE_NETBIRD_SERVICE_SCRIPT), "--normalize-collection", field],
        input=json.dumps(payload),
        text=True,
        capture_output=True,
        check=True,
    )
    return json.loads(result.stdout)


def test_ensure_netbird_service_normalizes_live_and_legacy_api_shapes():
    live_clusters = [
        {
            "id": "netbird-proxy-20260522080504",
            "address": "bierineenweek.nl",
            "connected_proxies": 1,
        }
    ]
    legacy_clusters = {"clusters": live_clusters}
    legacy_domains = {"results": [{"domain": "authentik.example.test", "id": "domain-1"}]}
    item_services = {"items": [{"domain": "authentik.example.test", "name": "authentik"}]}
    resource_response = {"resources": [{"id": "resource-1", "address": "10.96.0.1"}]}

    assert normalize_netbird_collection(live_clusters, "clusters") == live_clusters
    assert normalize_netbird_collection(legacy_clusters, "clusters") == live_clusters
    assert normalize_netbird_collection(legacy_domains, "domains") == legacy_domains["results"]
    assert normalize_netbird_collection(item_services, "services") == item_services["items"]
    assert (
        normalize_netbird_collection(resource_response, "resources")
        == resource_response["resources"]
    )
    assert normalize_netbird_collection({"domains": None}, "domains") == []
    assert normalize_netbird_collection("not-a-collection", "clusters") == []


def test_netbird_traefik_alias_patcher_preserves_labels_and_adds_only_alias():
    spec = importlib.util.spec_from_file_location(
        "patch_netbird_traefik_alias",
        PATCH_NETBIRD_TRAEFIK_ALIAS_SCRIPT,
    )
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)

    compose = {
        "services": {
            "traefik": {
                "image": "traefik:v3",
                "labels": [
                    "traefik.http.routers.netbird-dashboard.rule=Host(`netbird.example.test`)",
                    "traefik.http.routers.netbird-dashboard.tls=true",
                ],
                "networks": {
                    "netbird": {"aliases": ["traefik"]},
                    "default": {},
                },
            },
            "proxy": {
                "image": "netbirdio/netbird:0.70.5",
                "labels": {
                    "traefik.tcp.routers.proxy-passthrough.rule": (
                        "HostSNI(`*`) && !HostSNI(`netbird.example.test`)"
                    )
                },
            },
        },
        "networks": {"netbird": {}, "default": {}},
    }
    traefik_labels = list(compose["services"]["traefik"]["labels"])
    proxy_yaml = yaml.safe_dump(compose["services"]["proxy"], sort_keys=False)

    module.patch_compose_data(compose, "netbird.example.test")

    assert compose["services"]["traefik"]["labels"] == traefik_labels
    assert yaml.safe_dump(compose["services"]["proxy"], sort_keys=False) == proxy_yaml
    assert compose["services"]["traefik"]["networks"]["netbird"]["aliases"] == [
        "traefik",
        "netbird.example.test",
    ]
    assert compose["services"]["traefik"]["networks"]["default"] == {}

    once = yaml.safe_dump(compose, default_flow_style=False, sort_keys=False)
    module.patch_compose_data(compose, "netbird.example.test")
    twice = yaml.safe_dump(compose, default_flow_style=False, sort_keys=False)
    assert twice == once


def test_netbird_service_hostnames_match_ingress_routes():
    opencloud_text = OPENCLOUD_STEP_SCRIPT.read_text(encoding="utf-8")
    jitsi_text = (
        REPO_ROOT / "categories" / "apps" / "steps" / "install-jitsi" / "run.sh"
    ).read_text(encoding="utf-8")
    nextcloud_text = (
        REPO_ROOT / "categories" / "apps" / "steps" / "install-nextcloud" / "run.sh"
    ).read_text(encoding="utf-8")
    matrix_text = (
        REPO_ROOT / "categories" / "apps" / "steps" / "install-matrix" / "run.sh"
    ).read_text(encoding="utf-8")
    loki_text = (
        REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-loki" / "run.sh"
    ).read_text(encoding="utf-8")
    velero_text = (
        REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-velero-ui" / "run.sh"
    ).read_text(encoding="utf-8")
    argocd_text = (
        REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-argocd" / "run.sh"
    ).read_text(encoding="utf-8")
    dashy_text = (
        REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-dashy-dashboard" / "run.sh"
    ).read_text(encoding="utf-8")

    assert '--service-domain "opencloud-collabora.${public_zone_name}"' in opencloud_text
    assert '--service-domain "collabora.${public_zone_name}"' not in opencloud_text
    assert '--service-domain "opencloud-wopiserver.${public_zone_name}"' in opencloud_text
    assert '--service-name "auth-jitsi"' in jitsi_text
    assert '--service-domain "auth-jitsi.${public_zone_name}"' in jitsi_text
    assert "jitsi-broker.${public_zone_name}" not in jitsi_text
    assert '--service-domain "nextcloud-collabora.${public_zone_name}"' in nextcloud_text
    for host in ["chat", "matrix", "element-admin", "account", "mrtc"]:
        assert f'--service-domain "{host}.${{public_zone_name}}"' in matrix_text
    assert '--service-domain "loki.${public_zone_name}"' in loki_text
    assert '--service-domain "velero-ui.${public_zone_name}"' in velero_text
    assert '--service-name "argocd"' in argocd_text
    assert (
        '--service-domain "argocd.$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")"'
        in argocd_text
    )
    assert '--service-domain "admin.${public_zone_name}"' in dashy_text
    assert '--service-name "hubble"' in (
        REPO_ROOT
        / "categories"
        / "talos-cluster"
        / "steps"
        / "install-management-consoles"
        / "run.sh"
    ).read_text(encoding="utf-8")
    assert '--service-name "forgejo"' in (
        REPO_ROOT
        / "categories"
        / "talos-cluster"
        / "steps"
        / "install-management-consoles"
        / "run.sh"
    ).read_text(encoding="utf-8")


def test_matrix_app_manifest_uses_supported_chart_values():
    text = MATRIX_APP_MANIFEST.read_text(encoding="utf-8")

    assert "releaseName: ess" in text
    assert (
        'serverName: "matrix.{{index .metadata.annotations "twinbox.io/public-zone-name"}}"' in text
    )
    assert "synapse:" in text
    assert "elementWeb:" in text
    assert "matrixAuthenticationService:" in text
    assert "elementAdmin:" in text
    assert "matrixRTC:" in text
    assert "configSecret: matrix-config" in text
    assert "configSecretKey: oidc-upstream.yaml" in text
    assert 'host: "matrix.' in text
    assert 'host: "chat.' in text
    assert 'host: "account.' in text
    assert 'host: "element-admin.' in text
    assert 'host: "mrtc.' in text
    assert "twinbox.io/public-zone-name" in text
    assert "extraEnv:" not in text
    assert "valueFrom:" not in text
    assert "ingress.enabled" not in text
    assert "wellknownDelegation" not in text


def test_matrix_values_disable_chart_ingress_and_well_known():
    text = MATRIX_VALUES.read_text(encoding="utf-8")

    assert "className: twinbox-disabled" in text
    assert "wellKnownDelegation:\n  enabled: false" in text
    assert "ingress.enabled" not in text
    assert "wellknownDelegation" not in text


def test_matrix_ingressroutes_target_chart_services():
    text = MATRIX_INGRESSROUTE.read_text(encoding="utf-8")

    assert "kind: IngressRoute" in text
    assert "Host(`matrix.__ZONE_NAME__`)" in text
    assert "Host(`chat.__ZONE_NAME__`)" in text
    assert "Host(`account.__ZONE_NAME__`)" in text
    assert "Host(`element-admin.__ZONE_NAME__`)" in text
    assert "Host(`mrtc.__ZONE_NAME__`)" in text
    assert "PathPrefix(`/sfu/get`)" in text
    assert "PathPrefix(`/get_token`)" in text
    assert "name: ess-synapse" in text
    assert "name: ess-element-web" in text
    assert "name: ess-matrix-authentication-service" in text
    assert "name: ess-element-admin" in text
    assert "name: ess-matrix-rtc-authorisation-service" in text
    assert "name: ess-matrix-rtc-sfu" in text
    assert "port: 8008" in text
    assert "port: 8080" in text
    assert "port: 7880" in text
    assert "ess-synapse-haproxy" not in text
    assert "port: 443" not in text


def test_matrix_install_step_waits_on_specific_resources():
    text = MATRIX_STEP_SCRIPT.read_text(encoding="utf-8")

    assert "matrix_oidc_upstream_config=" in text
    assert "MATRIX_OIDC_UPSTREAM_CONFIG" in text
    assert "MATRIX_OIDC_ENABLED_IDPS" in text
    assert 'wait_for_named_resource_ready "databases" "cluster" "matrix-synapse-db"' in text
    assert 'wait_for_named_resource_ready "databases" "cluster" "matrix-mas-db"' in text
    assert (
        'wait_for_named_resource_ready "databases" "externalsecret" "matrix-synapse-db-credentials"'
        in text
    )
    assert (
        'wait_for_named_resource_ready "databases" "externalsecret" "matrix-mas-db-credentials"'
        in text
    )
    assert 'wait_for_named_resource_ready "matrix" "externalsecret" "matrix-config"' in text
    assert (
        'wait_for_named_resource_ready "matrix" "externalsecret" "matrix-synapse-db-credentials"'
        in text
    )
    assert (
        'wait_for_named_resource_ready "matrix" "externalsecret" "matrix-mas-db-credentials"'
        in text
    )
    assert 'wait_for_named_resource_ready "matrix" "externalsecret" "matrix-runtime"' in text
    assert 'wait_for_statefulset_ready "matrix" "ess-synapse-main"' in text
    assert 'wait_for_deployment_rollout "matrix" "ess-haproxy"' in text
    assert 'wait_for_deployment_rollout "matrix" "ess-matrix-rtc-authorisation-service"' in text
    assert 'wait_for_resources_ready "databases" "cluster"' not in text
    assert 'wait_for_resources_ready "databases" "externalsecret"' not in text
    assert 'wait_for_resources_ready "matrix" "externalsecret"' not in text
    assert 'wait_for_statefulset_ready "matrix" "ess-synapse"' not in text


def test_matrix_external_secret_renders_oidc_upstream_config():
    text = MATRIX_EXTERNALSECRET.read_text(encoding="utf-8")

    assert "engineVersion: v2" in text
    assert "type: Opaque" in text
    assert "oidc-upstream.yaml: |-" in text
    assert "MATRIX_OIDC_UPSTREAM_CONFIG" in text
    assert "MAS_OIDC_CLIENT_ID" not in text
    assert "MATRIX_OIDC_ENABLED_IDPS" not in text


def test_netbird_proxy_uses_traefik_webnetbird_origin():
    network_text = NETBIRD_NETWORK_MODULE_MAIN.read_text(encoding="utf-8")
    proxy_services_text = NETBIRD_PROXY_SERVICES_MODULE_MAIN.read_text(encoding="utf-8")
    proxy_services_vars_text = NETBIRD_PROXY_SERVICES_MODULE_VARS.read_text(encoding="utf-8")
    authentik_ingress_text = AUTHENTIK_INGRESSROUTE.read_text(encoding="utf-8")
    authentik_netbird_middleware_text = AUTHENTIK_NETBIRD_FORWARDED_HEADERS_MIDDLEWARE.read_text(
        encoding="utf-8"
    )
    platform_ingress_text = PLATFORM_INGRESS_APP.read_text(encoding="utf-8")
    platform_kustomization_text = KUSTOMIZATION.read_text(encoding="utf-8")
    traefik_netbird_service_text = TRAEFIK_NETBIRD_SERVICE.read_text(encoding="utf-8")
    traefik_values_text = _traefik_values_text()

    assert 'data "netbird_group" "all"' in network_text
    assert 'name = "All"' in network_text
    assert "traefik_resource_type" in network_text
    assert 'resource "netbird_setup_key" "proxy"' in network_text
    assert 'resource "netbird_route" "k8s_pods"' in network_text
    assert 'output "proxy_setup_key"' in (
        REPO_ROOT / "infra" / "opentofu" / "netbird-network" / "outputs.tf"
    ).read_text(encoding="utf-8")
    assert 'resource "netbird_policy" "proxy_to_traefik_https"' in network_text
    assert 'resource "netbird_policy" "proxy_to_traefik_http"' not in network_text

    proxy_policy = re.search(
        r'resource\s+"netbird_policy"\s+"proxy_to_traefik_https"\s+\{'
        r'(.*?)(?=\nresource\s+"netbird_policy"|\Z)',
        network_text,
        flags=re.DOTALL,
    )
    assert proxy_policy
    proxy_policy_body = proxy_policy.group(1)
    assert "sources       = [data.netbird_group.all.id]" in proxy_policy_body
    assert "sources       = [netbird_group.proxy.id]" not in proxy_policy_body
    assert 'ports         = ["8082"]' in proxy_policy_body
    assert 'ports         = ["443"]' not in proxy_policy_body
    assert 'ports         = ["8443"]' not in proxy_policy_body
    assert "type = local.traefik_resource_type" in proxy_policy_body
    assert "groups      = [data.netbird_group.all.id, netbird_group.proxy.id]" in network_text

    assert "traefik_target_type" in proxy_services_text
    assert "target_clusters" in proxy_services_text
    assert "cluster.address == var.netbird_proxy_domain" in proxy_services_text
    assert "cluster.connected_proxies" in proxy_services_text
    assert "data.netbird_reverse_proxy_clusters.all.clusters[0].address" not in proxy_services_text
    assert 'variable "netbird_proxy_domain"' in proxy_services_vars_text
    assert "target_type = local.traefik_target_type" in proxy_services_text
    assert "port        = 8082" in proxy_services_text
    assert "port        = 443" not in proxy_services_text
    assert "port        = 8443" not in proxy_services_text
    assert 'protocol    = "http"' in proxy_services_text
    assert 'protocol    = "https"' not in proxy_services_text
    assert "skip_tls_verify = false" in proxy_services_text
    assert not re.search(r"port\s*=\s*80(?:\D|$)", proxy_services_text)

    assert "websecure:" in traefik_values_text
    assert "exposedPort: 443" in traefik_values_text
    assert "webnetbird:" in traefik_values_text
    assert "port: 8082" in traefik_values_text
    assert "exposedPort: 8082" in traefik_values_text
    assert "name: traefik-netbird" in traefik_netbird_service_text
    assert "namespace: traefik" in traefik_netbird_service_text
    assert "clusterIP: None" in traefik_netbird_service_text
    assert "targetPort: webnetbird" in traefik_netbird_service_text
    assert "traefik/traefik-netbird-service.yaml" in platform_kustomization_text
    assert "management-consoles/beszel-ingressroute.yaml" in platform_kustomization_text
    assert "management-consoles/beszel-service.yaml" in platform_kustomization_text
    assert "management-consoles/forgejo-ingressroute.yaml" in platform_kustomization_text
    assert "management-consoles/forgejo-service.yaml" in platform_kustomization_text

    assert "name: authentik-netbird" in authentik_ingress_text
    netbird_route_text = authentik_ingress_text.split("name: authentik-netbird", 1)[1]
    assert "entryPoints:\n    - webnetbird" in netbird_route_text
    assert "Host(`authentik.__ZONE_NAME__`)" in netbird_route_text
    assert "name: authentik-netbird-forwarded-headers" in netbird_route_text
    assert "name: authentik-cors" in netbird_route_text
    assert "name: authentik-server" in netbird_route_text
    assert "tls:" not in netbird_route_text
    assert "name: authentik-netbird-forwarded-headers" in authentik_netbird_middleware_text
    assert "X-Forwarded-Proto: https" in authentik_netbird_middleware_text
    assert 'X-Forwarded-Port: "443"' in authentik_netbird_middleware_text
    assert "authentik/netbird-forwarded-headers-middleware.yaml" in platform_kustomization_text
    assert "name: authentik-netbird" in platform_ingress_text
    assert (
        'Host(`authentik.{{index .metadata.annotations "twinbox.io/public-zone-name"}}`)'
        in platform_ingress_text
    )


def test_netbird_lan_and_exit_routes_are_opt_in():
    network_text = NETBIRD_NETWORK_MODULE_MAIN.read_text(encoding="utf-8")
    vars_text = (REPO_ROOT / "infra" / "opentofu" / "netbird-network" / "variables.tf").read_text(
        encoding="utf-8"
    )
    outputs_text = (REPO_ROOT / "infra" / "opentofu" / "netbird-network" / "outputs.tf").read_text(
        encoding="utf-8"
    )

    assert 'variable "management_lan_cidrs"' in vars_text
    assert 'variable "exit_node_skip_auto_apply"' in vars_text
    assert 'variable "bastion_ssh_port"' in vars_text
    assert 'resource "netbird_group" "management_lan_routers"' in network_text
    assert 'resource "netbird_group" "bastion_exit_routers"' in network_text
    assert 'resource "netbird_group" "browser_ssh"' in network_text
    assert 'resource "netbird_group" "exit_node_users"' in network_text
    assert 'name = "${local.name_prefix}-exit-node-users"' in network_text
    assert 'resource "netbird_setup_key" "management_lan_router"' in network_text
    assert 'resource "netbird_setup_key" "bastion_exit_router"' in network_text
    assert 'resource "netbird_setup_key" "browser_ssh"' in network_text
    assert 'output "management_lan_router_setup_key"' in outputs_text
    assert 'output "bastion_exit_router_setup_key"' in outputs_text
    assert 'output "browser_ssh_group_id"' in outputs_text
    assert 'output "browser_ssh_setup_key"' in outputs_text
    assert 'output "exit_node_users_group_id"' in outputs_text

    lan_route = re.search(
        r'resource\s+"netbird_route"\s+"management_lan"\s+\{'
        r'(.*?)(?=\nresource\s+"netbird_route"|\Z)',
        network_text,
        flags=re.DOTALL,
    )
    assert lan_route
    lan_body = lan_route.group(1)
    assert "for_each = toset(var.management_lan_cidrs)" in lan_body
    assert (
        "peer_groups     = [netbird_group.management_vm.id, netbird_group.management_lan_routers.id]"
        in lan_body
    )
    assert (
        "groups          = [netbird_group.admins.id, netbird_group.exit_node_users.id]" in lan_body
    )
    assert "masquerade      = true" in lan_body
    assert "skip_auto_apply = var.exit_node_skip_auto_apply" in lan_body

    exit_route = re.search(
        r'resource\s+"netbird_route"\s+"hetzner_internet_exit"\s+\{'
        r'(.*?)(?=\nresource\s+"netbird_policy"|\Z)',
        network_text,
        flags=re.DOTALL,
    )
    assert exit_route
    exit_body = exit_route.group(1)
    assert 'network         = "0.0.0.0/0"' in exit_body
    assert "peer_groups     = [netbird_group.bastion_exit_routers.id]" in exit_body
    assert (
        "groups          = [netbird_group.admins.id, netbird_group.exit_node_users.id]" in exit_body
    )
    assert "masquerade      = true" in exit_body
    assert "skip_auto_apply = var.exit_node_skip_auto_apply" in exit_body

    assert 'protocol      = "icmp"' in network_text
    assert "exit_node_users_to_management_lan_routers_icmp" in network_text
    assert "exit_node_users_to_bastion_exit_routers_icmp" in network_text
    assert 'resource "netbird_policy" "admin_to_bastion_ssh"' in network_text
    assert 'resource "netbird_policy" "browser_ssh_to_management_vm_ssh"' in network_text
    assert 'resource "netbird_policy" "browser_ssh_to_bastion_ssh"' in network_text
    assert "sources       = [netbird_group.browser_ssh.id]" in network_text
    assert "destinations  = [netbird_group.proxy.id]" in network_text
    assert "destinations  = [netbird_group.management_vm.id]" in network_text
    assert "ports         = [tostring(var.bastion_ssh_port)]" in network_text


def test_adguard_install_uses_management_vm_dns_forwarder_for_netbird_dns():
    text = ADGUARD_STEP_SCRIPT.read_text(encoding="utf-8")

    assert "setup-dns-forwarder.sh" in text
    assert 'bash "$WORKSPACE_ROOT/scripts/manager/setup-dns-forwarder.sh"' in text
    assert "admins_group_id" in text
    assert "exit_node_users_group_id" in text
    assert '--group-id "$adguard_dns_group_id"' in text
    assert '--group-id "$admins_group_id"' in text
    assert '--group-id "$exit_node_users_group_id"' in text
    assert '--nameserver-ip "$mgmt_netbird_ip"' in text
    assert "--nameserver-port 5354" in text
    assert "Management VM NetBird IP" in text
    assert "netbird status" in text
    assert "/api/peers?name=" in text
    assert '"Authorization": f"Token {token}"' in text
    assert '"twinbox-mgmt-${cluster_slug}"' in text


def test_netbird_dns_zone_helper_manages_custom_zone_and_records():
    text = NETBIRD_DNS_ZONE_SCRIPT.read_text(encoding="utf-8")

    assert "/api/dns/zones" in text
    assert "distribution_groups" in text
    assert "enable_search_domain" in text
    assert "args.group_id" in text
    assert "records_url" in text
    assert '"type": "A"' in text
    assert '"ttl": 300' in text
    assert "PUT" in text
    assert "POST" in text
    assert '"Authorization": f"Token {token}"' in text


def test_netbird_dns_nameserver_helper_supports_multiple_groups():
    text = NETBIRD_DNS_NAMESERVER_SCRIPT.read_text(encoding="utf-8")

    assert 'parser.add_argument("--group-id", action="append", required=True)' in text
    assert "blocked_groups" in text
    assert '"groups": list(dict.fromkeys(args.group_id))' in text
    assert '"Authorization": f"Token {token}"' in text


def test_dns_forwarder_restarts_when_port_forward_or_proxy_exits():
    text = SETUP_DNS_FORWARDER_SCRIPT.read_text(encoding="utf-8")

    assert "cleanup()" in text
    assert 'kill \\"\\${proxy_pid:-}\\" \\"\\${pf_pid:-}\\"' in text
    assert 'if ! kill -0 \\"\\$pf_pid\\"' in text
    assert "DNS forwarder port-forward exited before becoming ready" in text
    assert "DNS forwarder port-forward did not become ready" in text
    assert "proxy_pid=\\$!" in text
    assert 'wait -n \\"\\$pf_pid\\" \\"\\$proxy_pid\\"' in text
    assert "DNS forwarder child process exited; restarting container" in text
    assert "exit 1" in text


def test_netbird_admin_access_uses_reachable_host_docker_daemon():
    text = NETBIRD_ADMIN_ACCESS_STEP_SCRIPT.read_text(encoding="utf-8")

    assert "docker info >/dev/null 2>&1" in text
    assert "netbird-management-lan-router-${cluster_id}.json" in text
    assert "netbird-admin-access-${cluster_id}.json" in text
    assert 'secret_file="$lan_router_secret"' in text
    assert "docker volume create twinbox-netbird" in text
    assert "--network host" in text
    assert "--cap-add NET_ADMIN" in text
    assert "-v /dev/net/tun:/dev/net/tun" in text
    assert "Docker CLI is available, but the host Docker daemon is not reachable" in text


def test_netbird_network_policies_use_single_rule_per_policy():
    text = NETBIRD_NETWORK_MODULE_MAIN.read_text(encoding="utf-8")

    policy_blocks = re.findall(
        r'resource\s+"netbird_policy"\s+"([^"]+)"\s+\{(.*?)(?=\nresource\s+"netbird_policy"|\Z)',
        text,
        flags=re.DOTALL,
    )

    assert policy_blocks
    assert "admin_to_management_vm" not in {name for name, _ in policy_blocks}
    assert "proxy_to_traefik" not in {name for name, _ in policy_blocks}

    for name, body in policy_blocks:
        assert body.count("\n  rule {") == 1, name

    assert "adguard_dns_to_k8s_routers" in {name for name, _ in policy_blocks}
    assert "adguard_dns_to_k8s_routers_tcp" in {name for name, _ in policy_blocks}
    assert "adguard_dns_to_management_vm" in {name for name, _ in policy_blocks}
    assert "adguard_dns_to_management_vm_tcp" in {name for name, _ in policy_blocks}
    assert "admin_to_bastion_ssh" in {name for name, _ in policy_blocks}
    assert "browser_ssh_to_management_vm_ssh" in {name for name, _ in policy_blocks}
    assert "browser_ssh_to_bastion_ssh" in {name for name, _ in policy_blocks}
    assert (
        "sources       = [netbird_group.adguard_dns.id, netbird_group.admins.id, netbird_group.exit_node_users.id]"
        in text
    )


def test_netbird_routing_peer_uses_pinned_image_tag():
    deployment_text = NETBIRD_ROUTING_PEER_DEPLOYMENT.read_text(encoding="utf-8")
    termix_deployment_text = TERMIX_DEPLOYMENT.read_text(encoding="utf-8")
    pinned_defaults_text = PINNED_DEFAULTS.read_text(encoding="utf-8")
    pinned_match = re.search(r"^PINNED_NETBIRD_VERSION=(\S+)$", pinned_defaults_text, re.M)

    assert pinned_match
    assert "__NETBIRD_VERSION__" not in deployment_text
    assert f"image: netbirdio/netbird:{pinned_match.group(1)}" in deployment_text
    assert f"image: netbirdio/netbird:{pinned_match.group(1)}" in termix_deployment_text


def test_gitops_app_manifests_and_platform_routes_are_openbao_backed():
    longhorn_app_text = LONGHORN_APP.read_text(encoding="utf-8")
    external_secrets_app_text = (REPO_ROOT / "gitops" / "apps" / "external-secrets.yaml").read_text(
        encoding="utf-8"
    )
    external_secrets_values_text = (
        REPO_ROOT / "gitops" / "values" / "external-secrets.yaml"
    ).read_text(encoding="utf-8")
    freshrss_run_text = FRESHRSS_STEP_SCRIPT.read_text(encoding="utf-8")
    freshrss_app_text = FRESHRSS_APP.read_text(encoding="utf-8")
    vaultwarden_run_text = VAULTWARDEN_STEP_SCRIPT.read_text(encoding="utf-8")
    vaultwarden_app_text = VAULTWARDEN_APP.read_text(encoding="utf-8")
    headlamp_app_text = HEADLAMP_APP.read_text(encoding="utf-8")
    traefik_values_text = _traefik_values_text()
    traefik_values = yaml.safe_load(traefik_values_text)
    crowdsec_values_text = _crowdsec_values_text()
    traefik_externalsecret_text = _traefik_dashboard_externalsecret_text()
    crowdsec_bouncer_externalsecret_text = _crowdsec_bouncer_externalsecret_text()
    traefik_crowdsec_bouncer_externalsecret_text = _traefik_crowdsec_bouncer_externalsecret_text()
    headlamp_ingressroute_text = HEADLAMP_INGRESSROUTE.read_text(encoding="utf-8")
    authentik_ingressroute_text = (
        REPO_ROOT / "gitops" / "platform" / "authentik" / "ingressroute.yaml"
    ).read_text(encoding="utf-8")
    authentik_cors_text = (
        REPO_ROOT / "gitops" / "platform" / "authentik" / "cors-middleware.yaml"
    ).read_text(encoding="utf-8")
    grafana_ingressroute_text = GRAFANA_INGRESSROUTE.read_text(encoding="utf-8")

    assert "chart: longhorn" in longhorn_app_text
    assert "__LONGHORN_VALUES__" in longhorn_app_text
    assert "ServerSideApply=true" in external_secrets_app_text
    assert "certController:" in external_secrets_values_text
    assert "create: true" in external_secrets_values_text
    assert "enabled: trueß∑" not in traefik_values_text
    assert "enabled: true" in traefik_values_text
    assert isinstance(traefik_values["providers"]["file"]["content"], dict)
    assert "logs" not in traefik_values
    assert traefik_values["log"]["level"] == "INFO"
    assert traefik_values["accessLog"]["enabled"] is True
    assert "github.com/BetterCorp/cloudflarewarp" in traefik_values_text
    assert "version: v1.3.3" in traefik_values_text
    assert "github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin" in traefik_values_text
    assert "version: v1.6.0" in traefik_values_text
    assert "abortOnPluginFailure" not in traefik_values_text
    assert "cloudflarewarp@file,crowdsec@file" in traefik_values_text
    assert (
        "crowdsecLapiHost: crowdsec-service.crowdsec.svc.cluster.local:8080" in traefik_values_text
    )
    assert "crowdsecLapiKeyFile: /run/secrets/crowdsec/lapi-key" in traefik_values_text
    assert "mountPath: /run/secrets/crowdsec" in traefik_values_text
    assert "crowdsecurity/traefik" in crowdsec_values_text
    assert "podName: traefik-*" in crowdsec_values_text
    assert "program: traefik" in crowdsec_values_text
    assert "cluster-public-zone.sh" in freshrss_run_text
    assert "Could not determine cluster DNS domain" in freshrss_run_text
    assert (
        'rendered_manifest="$(mktemp "${TMPDIR:-/tmp}/freshrss-application-XXXXXX")"'
        in freshrss_run_text
    )
    assert "Applying FreshRSS Argo CD application" in freshrss_run_text
    assert (
        'sed "s/__ZONE_NAME__/${public_zone_name}/g" "$manifest_path" >"$rendered_manifest"'
        in freshrss_run_text
    )
    assert '--manifest "$rendered_manifest"' in freshrss_run_text
    assert "kind: Application" in freshrss_app_text
    assert "path: gitops/platform-apps/freshrss" in freshrss_app_text
    assert "kustomize:" in freshrss_app_text
    assert "Host(`freshrss.__ZONE_NAME__`)" in FRESHRSS_INGRESSROUTE.read_text(encoding="utf-8")
    assert "cluster-public-zone.sh" in vaultwarden_run_text
    assert "sync-openbao-global-secret.sh" in vaultwarden_run_text
    assert "VAULTWARDEN_ADMIN_TOKEN" in vaultwarden_run_text
    assert "apply-argocd-application.sh" in vaultwarden_run_text
    assert '--application "vaultwarden"' in vaultwarden_run_text
    assert "kind: Application" in vaultwarden_app_text
    assert "path: gitops/platform-apps/vaultwarden" in vaultwarden_app_text
    assert "path: gitops/databases/vaultwarden" in vaultwarden_app_text
    assert "Host(`vaultwarden.__ZONE_NAME__`)" in VAULTWARDEN_INGRESSROUTE.read_text(
        encoding="utf-8"
    )
    assert "kind: Application" in headlamp_app_text
    assert "path: gitops/platform-apps/headlamp" in headlamp_app_text
    assert "middlewares:" in authentik_ingressroute_text
    assert "name: authentik-cors" in authentik_ingressroute_text
    assert "kind: Middleware" in authentik_cors_text
    assert "accessControlAllowOriginList" in authentik_cors_text
    assert "https://admin.__ZONE_NAME__" in authentik_cors_text
    assert "https://opencloud.__ZONE_NAME__" in authentik_cors_text
    assert "customResponseHeaders" not in authentik_cors_text
    assert "Access-Control-Allow-Origin" not in authentik_cors_text
    assert "Host(`headlamp.__ZONE_NAME__`)" in headlamp_ingressroute_text
    assert "Host(`grafana.__ZONE_NAME__`)" in grafana_ingressroute_text
    assert "Host(`hubble.__ZONE_NAME__`)" in HUBBLE_INGRESSROUTE.read_text(encoding="utf-8")
    assert "kind: Middleware" in HUBBLE_AUTHENTIK_FORWARDAUTH_MIDDLEWARE.read_text(encoding="utf-8")
    assert "Host(`pgadmin4.__ZONE_NAME__`)" in PGADMIN_INGRESSROUTE.read_text(encoding="utf-8")
    assert "pgadmin4-data" in PGADMIN_PVC.read_text(encoding="utf-8")
    assert "pgadmin4-bootstrap" in PGADMIN_DEPLOYMENT.read_text(encoding="utf-8")
    assert "dpage/pgadmin4:9.16" in PGADMIN_DEPLOYMENT.read_text(encoding="utf-8")
    assert "master-password-hook.sh" in PGADMIN_DEPLOYMENT.read_text(encoding="utf-8")
    assert "mountPath: /config" in PGADMIN_DEPLOYMENT.read_text(encoding="utf-8")
    assert "pgadmin4-servers.json" in PGADMIN_DEPLOYMENT.read_text(encoding="utf-8")
    assert "readinessProbe" in PGADMIN_DEPLOYMENT.read_text(encoding="utf-8")
    assert "configmap.yaml" in (
        REPO_ROOT / "gitops" / "platform-apps" / "pgadmin4" / "kustomization.yaml"
    ).read_text(encoding="utf-8")
    assert "pgadmin4" in PGADMIN_SERVICE.read_text(encoding="utf-8")
    assert "name: pgadmin4" not in PLATFORM_INGRESS_APP.read_text(encoding="utf-8")
    assert "pgadmin4" not in PLATFORM_INGRESS_APP.read_text(encoding="utf-8")
    assert "config:" in _headlamp_values_text()
    assert "oidc:" in _headlamp_values_text()
    assert "headlamp-oidc" in _headlamp_values_text()
    assert "headlamp/externalsecret.yaml" not in (
        REPO_ROOT / "gitops" / "platform" / "kustomization.yaml"
    ).read_text(encoding="utf-8")
    assert "hubble/authentik-forwardauth-middleware.yaml" in (
        REPO_ROOT / "gitops" / "platform" / "kustomization.yaml"
    ).read_text(encoding="utf-8")
    assert "hubble/ingressroute.yaml" in (
        REPO_ROOT / "gitops" / "platform" / "kustomization.yaml"
    ).read_text(encoding="utf-8")
    assert "crowdsec/bouncer-externalsecret.yaml" in (
        REPO_ROOT / "gitops" / "platform" / "kustomization.yaml"
    ).read_text(encoding="utf-8")
    assert "traefik/crowdsec-bouncer-externalsecret.yaml" in (
        REPO_ROOT / "gitops" / "platform" / "kustomization.yaml"
    ).read_text(encoding="utf-8")
    assert "pgadmin4/externalsecret.yaml" not in (
        REPO_ROOT / "gitops" / "platform" / "kustomization.yaml"
    ).read_text(encoding="utf-8")
    assert "kind: ExternalSecret" in _headlamp_oidc_externalsecret_text()
    assert "kind: ExternalSecret" in crowdsec_bouncer_externalsecret_text
    assert "name: openbao" in crowdsec_bouncer_externalsecret_text
    assert "secretKey: BOUNCER_KEY_traefik" in crowdsec_bouncer_externalsecret_text
    assert "property: lapi_key" in crowdsec_bouncer_externalsecret_text
    assert "kind: ExternalSecret" in traefik_crowdsec_bouncer_externalsecret_text
    assert "name: openbao" in traefik_crowdsec_bouncer_externalsecret_text
    assert "secretKey: lapi-key" in traefik_crowdsec_bouncer_externalsecret_text
    assert "property: lapi_key" in traefik_crowdsec_bouncer_externalsecret_text
    assert "HEADLAMP_CONFIG_OIDC_CLIENT_SECRET" in _headlamp_oidc_externalsecret_text()
    platform_ingress_app_text = (REPO_ROOT / "gitops" / "apps" / "platform-ingress.yaml").read_text(
        encoding="utf-8"
    )
    grafana_appset_text = GRAFANA_APP.read_text(encoding="utf-8")
    ntfy_appset_text = NTFY_APP.read_text(encoding="utf-8")
    assert "kind: ApplicationSet" in platform_ingress_app_text
    assert "name: platform-ingress-set" in platform_ingress_app_text
    assert "name: authentik-cors" in platform_ingress_app_text
    assert "name: hubble" in platform_ingress_app_text
    assert "accessControlAllowOriginList/0" in platform_ingress_app_text
    assert "accessControlAllowOriginList/1" in platform_ingress_app_text
    assert (
        'opencloud.{{index .metadata.annotations "twinbox.io/public-zone-name"}}'
        in platform_ingress_app_text
    )
    assert "customResponseHeaders/Access-Control-Allow-Origin" not in platform_ingress_app_text
    assert (
        'hubble.{{index .metadata.annotations "twinbox.io/public-zone-name"}}'
        in platform_ingress_app_text
    )
    assert (
        'pgadmin4.{{index .metadata.annotations "twinbox.io/public-zone-name"}}'
        not in platform_ingress_app_text
    )
    assert (
        'cloudtty.{{index .metadata.annotations "twinbox.io/public-zone-name"}}'
        not in platform_ingress_app_text
    )
    assert (
        'Host(`start.{{index .metadata.annotations "twinbox.io/public-zone-name"}}`)'
        not in platform_ingress_app_text
    )
    assert (
        'seaweedfs.{{index .metadata.annotations "twinbox.io/public-zone-name"}}'
        in platform_ingress_app_text
    )
    assert (
        'seaweedfs-admin.{{index .metadata.annotations "twinbox.io/public-zone-name"}}'
        in platform_ingress_app_text
    )
    assert "kind: ApplicationSet" in grafana_appset_text
    assert "name: grafana-set" in grafana_appset_text
    assert "path: gitops/platform-apps/grafana" in grafana_appset_text
    assert "kind: ApplicationSet" in ntfy_appset_text
    assert "name: ntfy-set" in ntfy_appset_text
    assert "path: gitops/platform-apps/ntfy" in ntfy_appset_text
    assert "name: traefik-manager" not in platform_ingress_app_text
    assert (
        'traefik-manager.{{index .metadata.annotations "twinbox.io/public-zone-name"}}'
        not in platform_ingress_app_text
    )
    assert not (REPO_ROOT / "gitops" / "apps" / "cluster-config.yaml").exists()
    assert "kind: ExternalSecret" in traefik_externalsecret_text
    assert "kind: ClusterSecretStore" in traefik_externalsecret_text
    assert "name: openbao" in traefik_externalsecret_text
    assert "name: traefik-dashboard-auth" in traefik_externalsecret_text
    assert "secretKey: users" in traefik_externalsecret_text


def test_optional_apps_route_steady_state_through_argocd_sources():
    app_expectations = {
        "outline": (OUTLINE_APP, OUTLINE_DB_KUSTOMIZATION),
        "openwebui": (OPENWEBUI_APP, OPENWEBUI_DB_KUSTOMIZATION),
        "n8n": (N8N_APP, N8N_DB_KUSTOMIZATION),
        "hedgedoc": (HEDGEDOC_APP, HEDGEDOC_DB_KUSTOMIZATION),
        "paperless": (PAPERLESS_APP, PAPERLESS_DB_KUSTOMIZATION),
        "vaultwarden": (VAULTWARDEN_APP, VAULTWARDEN_DB_KUSTOMIZATION),
        "pixelfed": (PIXELFED_APP, PIXELFED_DB_KUSTOMIZATION),
    }

    step_expectations = {
        OUTLINE_STEP_SCRIPT: [
            "apply-argocd-application.sh",
            '--application "outline"',
            "gitops/apps/outline.yaml",
        ],
        OPENWEBUI_STEP_SCRIPT: [
            "apply-argocd-application.sh",
            '--application "openwebui"',
            "gitops/apps/openwebui.yaml",
        ],
        N8N_STEP_SCRIPT: [
            "apply-argocd-application.sh",
            '--application "n8n"',
            "gitops/apps/n8n.yaml",
        ],
        HEDGEDOC_STEP_SCRIPT: [
            "apply-argocd-application.sh",
            '--application "hedgedoc"',
            "gitops/apps/hedgedoc.yaml",
        ],
        PAPERLESS_STEP_SCRIPT: [
            "apply-argocd-application.sh",
            '--application "paperless"',
            "gitops/apps/paperless.yaml",
        ],
        VAULTWARDEN_STEP_SCRIPT: [
            "apply-argocd-application.sh",
            '--application "vaultwarden"',
            "gitops/apps/vaultwarden.yaml",
        ],
        PIXELFED_STEP_SCRIPT: [
            "apply-argocd-application.sh",
            '--application "pixelfed"',
            "gitops/apps/pixelfed.yaml",
        ],
    }

    forbidden_snippets = {
        OUTLINE_STEP_SCRIPT: [
            'kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/namespace.yaml"',
            'kubectl apply -f "$WORKSPACE_ROOT/gitops/platform-apps/outline/namespace.yaml"',
        ],
        OPENWEBUI_STEP_SCRIPT: [
            'kubectl apply -f "$WORKSPACE_ROOT/gitops/platform-apps/openwebui/namespace.yaml"',
            'kubectl apply -k "$WORKSPACE_ROOT/gitops/databases/openwebui"',
        ],
        N8N_STEP_SCRIPT: [
            'kubectl apply -f "$WORKSPACE_ROOT/gitops/platform-apps/n8n/namespace.yaml"',
            'kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/n8n/cluster.yaml"',
        ],
        HEDGEDOC_STEP_SCRIPT: [
            'kubectl apply -f "$WORKSPACE_ROOT/gitops/platform-apps/hedgedoc/namespace.yaml"',
            'kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/hedgedoc/cluster.yaml"',
        ],
        PAPERLESS_STEP_SCRIPT: [
            'kubectl apply -f "$WORKSPACE_ROOT/gitops/platform-apps/paperless/namespace.yaml"',
            'kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/paperless/cluster.yaml"',
        ],
        VAULTWARDEN_STEP_SCRIPT: [
            'kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/vaultwarden/cluster.yaml"',
        ],
        PIXELFED_STEP_SCRIPT: [
            'kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/pixelfed/cluster.yaml"',
        ],
    }

    for app_name, (app_path, db_path) in app_expectations.items():
        app_text = app_path.read_text(encoding="utf-8")
        db_text = db_path.read_text(encoding="utf-8")
        assert "kind: Application" in app_text
        assert f"path: gitops/platform-apps/{app_name}" in app_text
        assert f"path: gitops/databases/{app_name}" in app_text
        if app_name == "outline":
            optional_app_text = OUTLINE_OPTIONAL_APP.read_text(encoding="utf-8")
            assert 'index .metadata.labels "twinbox.io/resource-profile"' in optional_app_text
            assert 'dig "twinbox.io/resource-profile"' not in optional_app_text
        assert "namespace.yaml" not in db_text
        assert "cluster.yaml" in db_text or "externalsecret.yaml" in db_text

    for step_path, snippets in step_expectations.items():
        step_text = step_path.read_text(encoding="utf-8")
        for snippet in snippets:
            assert snippet in step_text
        for snippet in forbidden_snippets[step_path]:
            assert snippet not in step_text

    headlamp_run_text = (
        REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-headlamp" / "run.sh"
    ).read_text(encoding="utf-8")
    twinbox_portal_run_text = TWINBOX_PORTAL_STEP_SCRIPT.read_text(encoding="utf-8")
    assert "apply-argocd-application.sh" in headlamp_run_text
    assert "gitops/platform-apps/headlamp/externalsecret.yaml" not in headlamp_run_text
    assert "apply-argocd-application.sh" in twinbox_portal_run_text
    assert "gitops/platform-apps/twinbox-portal/namespace.yaml" not in twinbox_portal_run_text
    assert "gitops/platform-apps/twinbox-portal/deployment.yaml" not in twinbox_portal_run_text
    assert "gitops/platform-apps/twinbox-portal/ingressroute.yaml" not in twinbox_portal_run_text


def test_optional_apps_resource_profile_lookups_use_index_on_labels():
    manifest_paths = [
        REPO_ROOT / "gitops" / "optional-apps" / "hedgedoc.yaml",
        REPO_ROOT / "gitops" / "optional-apps" / "immich.yaml",
        REPO_ROOT / "gitops" / "optional-apps" / "n8n.yaml",
        REPO_ROOT / "gitops" / "optional-apps" / "nextcloud.yaml",
        REPO_ROOT / "gitops" / "optional-apps" / "outline.yaml",
        REPO_ROOT / "gitops" / "optional-apps" / "paperless.yaml",
        REPO_ROOT / "gitops" / "optional-apps" / "pixelfed.yaml",
        REPO_ROOT / "gitops" / "optional-apps" / "openwebui.yaml",
        REPO_ROOT / "gitops" / "optional-apps" / "vaultwarden.yaml",
    ]

    for manifest_path in manifest_paths:
        text = manifest_path.read_text(encoding="utf-8")
        assert 'index .metadata.labels "twinbox.io/resource-profile"' in text
        assert 'dig "twinbox.io/resource-profile"' not in text


def test_grafana_oidc_is_openbao_backed():
    grafana_values_text = _grafana_values_text()
    grafana_app_text = GRAFANA_APP.read_text(encoding="utf-8")
    grafana_externalsecret_text = _grafana_externalsecret_text()
    grafana_step_text = (
        REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-grafana" / "run.sh"
    ).read_text(encoding="utf-8")

    assert "adminPassword:" not in grafana_values_text
    assert "existingSecret: grafana-oidc" in grafana_values_text
    assert "envFromSecret: grafana-oidc" in grafana_values_text
    assert "path: gitops/platform-apps/grafana" in grafana_app_text
    assert "kind: ExternalSecret" in grafana_externalsecret_text
    assert "kind: ClusterSecretStore" in grafana_externalsecret_text
    assert "name: openbao" in grafana_externalsecret_text
    assert "name: grafana-oidc" in grafana_externalsecret_text
    assert "GF_AUTH_GENERIC_OAUTH_CLIENT_ID" in grafana_externalsecret_text
    assert "GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET" in grafana_externalsecret_text
    assert "secretKey: admin-user" in grafana_externalsecret_text
    assert "secretKey: admin-password" in grafana_externalsecret_text
    assert "Provisioning Authentik OIDC client for Grafana" in grafana_step_text
    assert '--secret-name "grafana-oidc"' in grafana_step_text
    assert "GF_SECURITY_ADMIN_USER" in grafana_step_text
    assert "GF_SECURITY_ADMIN_PASSWORD" in grafana_step_text


def test_grafana_managed_overview_dashboard_is_rewritten_for_twinbox():
    helper_text = GRAFANA_REFRESH_HELPER.read_text(encoding="utf-8")
    grafana_step_text = (
        REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-grafana" / "run.sh"
    ).read_text(encoding="utf-8")

    assert "managed-kubernetes-overview-dashboard" in helper_text
    assert "https://grafana.com/api/dashboards/24155/revisions/1/download" in helper_text
    assert '["${DS_MK8S}", "Prometheus"],' in helper_text
    assert '["${datasource}", "Prometheus"],' in helper_text
    assert '["${VAR_JOB}", "node-exporter"],' in helper_text
    assert "'cluster_name=\"$cluster\"', 'cluster_name=~\".*\"'" in helper_text
    assert "rewriteNodeExporterCpuQuery" in helper_text
    assert 'replace(/cluster_name="\\$cluster"/g, "")' in helper_text
    assert 'next.name === "datasource"' in helper_text
    assert '.regex = ".*"' in helper_text
    assert "refresh-grafana-dashboard.mjs" in grafana_step_text
    assert "managed-kubernetes-overview-dashboard" not in grafana_step_text
    assert "https://grafana.com/api/dashboards/24155/revisions/1/download" not in grafana_step_text
    assert '.regex = ".*"' not in grafana_step_text


def test_grafana_worker_refreshes_dashboard_after_cluster_jobs():
    worker_text = WORKER_JS.read_text(encoding="utf-8")

    assert "refreshGrafanaDashboard(" in worker_text
    assert "resolvePostRefreshSecretRuntime(" in worker_text
    assert "buildClusterWorkerSecretBundle(cluster)" in worker_text
    assert "withKubeconfigAliases({" in worker_text
    assert "postRefreshRuntime.cleanup()" in worker_text
    assert "scripts/manager/refresh-grafana-dashboard.mjs" in worker_text
    assert "reconcileGrafanaDashboardsOnStartup" in worker_text
    assert "manager-worker-startup" in worker_text
    assert "await refreshDashyConfig(" in worker_text
    assert "await refreshPortalConfig(" in worker_text
    assert "await refreshGrafanaDashboard(" in worker_text


def test_talos_module_is_vm_only_and_keeps_planned_outputs():
    main_text = _module_text()
    outputs_text = _module_outputs_text()
    compact_main_text = re.sub(r"\s+", " ", main_text)
    assert 'resource "proxmox_virtual_environment_vm" "node"' in main_text
    assert 'resource "proxmox_virtual_environment_file" "talos_nocloud"' not in main_text
    assert "talos_image_nodes" not in main_text
    assert 'resource "proxmox_virtual_environment_download_file" "talos"' not in main_text
    assert "content_type" not in compact_main_text
    assert "decompression_algorithm" not in compact_main_text
    assert "source_file {" not in main_text
    assert "path      = var.talos_image_local_path" not in main_text
    assert "node_name    = each.value" not in main_text
    assert 'machine   = "q35"' not in main_text
    assert 'boot_order = ["virtio0"]' in main_text
    assert "cdrom {" not in main_text
    assert 'dynamic "cdrom"' not in main_text
    assert "for_each = var.boot_from_disk ? [] : [1]" not in main_text
    assert "validation {" not in _module_variables_text()
    assert "boot_from_disk" not in _module_variables_text()
    assert "vm_host_map = var.vm_node_map" in compact_main_text
    assert (
        'talos_image_file_name = "talos-${var.cluster_slug}-${var.talos_image_cache_key}.raw"'
        in compact_main_text
    )
    assert (
        'talos_image_file_id = "${var.file_datastore}:import/${local.talos_image_file_name}"'
        in compact_main_text
    )
    assert "talos_image_disk_url" not in _module_variables_text()
    assert "merge(" not in main_text
    assert "import_from = local.talos_image_file_id" in compact_main_text
    assert "node_name = local.vm_host_map[each.key]" in compact_main_text
    assert "datastore_id = each.value.datastore_id" in compact_main_text
    assert "datastore_id = string" in re.sub(r"\s+", " ", _module_variables_text())
    assert 'variable "vm_datastore"' not in _module_variables_text()
    assert '--vm-storage-map "$current_vm_storage_map"' in PROVISION_NODES_SCRIPT.read_text(
        encoding="utf-8"
    )
    assert "file_id = proxmox_virtual_environment_download_file.talos" not in compact_main_text
    assert "file_id      = proxmox_virtual_environment_file.talos_nocloud.id" not in main_text
    assert "remove_legacy_talos_file_state" not in main_text
    assert 'file_format  = "raw"' not in main_text
    assert "agent {" in main_text
    assert "wait_for_ip {" in main_text
    assert "ipv4 = true" in main_text
    assert "reboot_after_update = false" in main_text
    assert 'type = "std"' in main_text
    assert "talos_machine_configuration_apply" not in main_text
    assert "talos_machine_bootstrap" not in main_text
    assert "talos_cluster_kubeconfig" not in main_text
    assert 'output "controlplane_vm_ids"' in outputs_text
    assert 'output "worker_vm_ids"' in outputs_text
    assert 'output "controlplane_ipv4_addresses"' in outputs_text
    assert 'output "worker_ipv4_addresses"' in outputs_text
    assert 'output "kubeconfig"' not in outputs_text


PROMETHEUS_APP = REPO_ROOT / "gitops" / "apps" / "prometheus.yaml"
PROMETHEUS_VALUES = REPO_ROOT / "gitops" / "values" / "prometheus.yaml"
METRICS_SERVER_APP = REPO_ROOT / "gitops" / "apps" / "metrics-server.yaml"
METRICS_SERVER_VALUES = REPO_ROOT / "gitops" / "values" / "metrics-server.yaml"
PROMETHEUS_INGRESSROUTE = (
    REPO_ROOT / "gitops" / "platform-apps" / "prometheus" / "ingressroute.yaml"
)
ALERTMANAGER_CONFIG = (
    REPO_ROOT / "gitops" / "platform-apps" / "prometheus" / "alertmanager-config.yaml"
)
LOKI_APP = REPO_ROOT / "gitops" / "apps" / "loki.yaml"
LOKI_VALUES = REPO_ROOT / "gitops" / "values" / "loki.yaml"
ALLOY_VALUES = REPO_ROOT / "gitops" / "values" / "alloy.yaml"
NTFY_APP = REPO_ROOT / "gitops" / "apps" / "ntfy.yaml"
NTFY_VALUES = REPO_ROOT / "gitops" / "values" / "ntfy.yaml"
NTFY_INGRESSROUTE = REPO_ROOT / "gitops" / "platform-apps" / "ntfy" / "ingressroute.yaml"
KUSTOMIZATION = REPO_ROOT / "gitops" / "platform" / "kustomization.yaml"
DATABASES_KUSTOMIZATION = REPO_ROOT / "gitops" / "databases" / "kustomization.yaml"
DATABASES_SHARED_KUSTOMIZATION = (
    REPO_ROOT / "gitops" / "databases" / "shared" / "kustomization.yaml"
)
AUTHENTIK_DB_CLUSTER = REPO_ROOT / "gitops" / "databases" / "authentik" / "cluster.yaml"
AUTHENTIK_DB_STORAGECLASS = REPO_ROOT / "gitops" / "databases" / "longhorn-single-storageclass.yaml"
DATABASES_NAMESPACE = REPO_ROOT / "gitops" / "databases" / "shared" / "namespace.yaml"


def _argocd_source_paths_with_kustomizations():
    source_paths = set()
    for manifest_root in [REPO_ROOT / "gitops" / "apps", REPO_ROOT / "gitops" / "optional-apps"]:
        for manifest_path in manifest_root.rglob("*.yaml"):
            text = manifest_path.read_text(encoding="utf-8")
            source_paths.update(re.findall(r"^\s*path:\s*(gitops/[^\s#]+)", text, re.MULTILINE))

    return sorted(
        path for path in source_paths if (REPO_ROOT / path / "kustomization.yaml").exists()
    )


def test_prometheus_argocd_app_uses_kube_prometheus_stack():
    text = PROMETHEUS_APP.read_text(encoding="utf-8")
    assert "kind: Application" in text
    assert "name: prometheus" in text
    assert "chart: kube-prometheus-stack" in text
    assert "prometheus-community.github.io/helm-charts" in text
    assert "$values/gitops/values/prometheus.yaml" in text
    assert "namespace: monitoring" in text


def test_metrics_server_argocd_app_uses_official_chart():
    text = METRICS_SERVER_APP.read_text(encoding="utf-8")
    assert "kind: Application" in text
    assert "name: metrics-server" in text
    assert "chart: metrics-server" in text
    assert "https://kubernetes-sigs.github.io/metrics-server/" in text
    assert 'targetRevision: "3.13.1"' in text
    assert "$values/gitops/values/metrics-server.yaml" in text
    assert "repoURL: __REPO_URL__" in text
    assert "targetRevision: __TARGET_REVISION__" in text
    assert "namespace: kube-system" in text


def test_metrics_server_values_configures_talos_friendly_args():
    text = METRICS_SERVER_VALUES.read_text(encoding="utf-8")
    assert "--kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname" in text
    assert "--kubelet-use-node-status-port" in text
    assert "--kubelet-insecure-tls" in text
    assert "--metric-resolution=15s" in text
    assert "cpu: 50m" in text
    assert "memory: 64Mi" in text
    assert "cpu: 200m" in text
    assert "memory: 256Mi" in text


def test_prometheus_installer_applies_metrics_server_first_without_kube_system_baseline():
    text = PROMETHEUS_SCRIPT.read_text(encoding="utf-8")
    metrics_server_index = text.index("gitops/apps/metrics-server.yaml")
    prometheus_index = text.index("gitops/apps/prometheus.yaml")
    assert metrics_server_index < prometheus_index
    assert '--application "metrics-server"' in text
    assert "--skip-namespace-baseline" in text
    assert '--application "prometheus"' in text


def test_prometheus_values_configures_alertmanager_and_storage():
    text = PROMETHEUS_VALUES.read_text(encoding="utf-8")
    assert "kube-prometheus-stack" not in text
    assert "serviceMonitorSelectorNilUsesHelmValues: false" in text
    assert "scrapeInterval: 300s" in text
    assert "retention: 2d" in text
    assert "alertmanager:" in text
    assert "enabled: true" in text
    assert "configSecret: alertmanager-config" in text
    assert "grafana:" in text
    assert "enabled: false" in text
    assert "storageClassName: longhorn-single" in text
    assert "memory: 1Gi" in text
    assert "cpu: 500m" in text
    assert "memory: 2Gi" in text
    assert "cpu: 2000m" in text
    assert "kube-state-metrics:" in text
    assert "memory: 256Mi" in text
    assert "cpu: 100m" in text
    assert "memory: 768Mi" in text
    assert "cpu: 750m" in text


def test_prometheus_ingressroute_exposes_ui():
    text = PROMETHEUS_INGRESSROUTE.read_text(encoding="utf-8")
    assert "kind: IngressRoute" in text
    assert "Host(`prometheus.__ZONE_NAME__`)" in text
    assert "prometheus-operated" in text
    assert "port: 9090" in text
    assert "webwiredoor" not in text


def test_alertmanager_config_routes_to_ntfy():
    text = ALERTMANAGER_CONFIG.read_text(encoding="utf-8")
    assert "name: alertmanager-config" in text
    assert "alertmanager.yaml:" in text
    assert "receiver: 'ntfy-warning'" in text
    assert 'severity="critical"' in text
    assert 'severity="emergency"' in text
    assert "name: 'ntfy-warning'" in text
    assert "name: 'ntfy-critical'" in text
    assert "name: 'ntfy-emergency'" in text
    assert "webhook_configs:" in text
    assert "ntfy.monitoring.svc.cluster.local" in text
    assert "priority=default" in text
    assert "priority=high" in text
    assert "priority=max" in text
    assert "send_resolved: true" in text


def test_loki_argocd_app_uses_loki_chart():
    text = LOKI_APP.read_text(encoding="utf-8")
    assert "kind: Application" in text
    assert "name: loki" in text
    assert "chart: loki" in text
    assert "grafana.github.io/helm-charts" in text
    assert "$values/gitops/values/loki.yaml" in text
    assert "namespace: monitoring" in text


def test_loki_values_configures_filesystem_storage():
    text = LOKI_VALUES.read_text(encoding="utf-8")
    assert "auth_enabled: false" in text
    assert "replication_factor: 1" in text
    assert "type: filesystem" in text
    assert "storageClass: longhorn-single" in text
    assert "storageClassName: longhorn-single" not in text
    assert "retention_period: 1d" in text


def test_alloy_values_keeps_pod_logs_to_core_platform_namespaces():
    text = ALLOY_VALUES.read_text(encoding="utf-8")

    assert 'action        = "keep"' in text
    assert 'source_labels = ["__meta_kubernetes_namespace"]' in text
    assert "kube-system|argocd|monitoring|longhorn-system" in text


def test_ntfy_argocd_app_uses_ntfy_chart():
    text = NTFY_APP.read_text(encoding="utf-8")
    assert "kind: Application" in text
    assert "name: ntfy" in text
    assert "chart: ntfy" in text
    assert "helm-charts.rm3l.org" in text
    assert "$values/gitops/values/ntfy.yaml" in text
    assert "namespace: monitoring" in text


def test_ntfy_values_configures_persistence():
    text = NTFY_VALUES.read_text(encoding="utf-8")
    assert "binwiederhier/ntfy" in text
    assert "strategy:" in text
    assert "type: Recreate" in text
    assert "storageClassName: longhorn" in text
    assert "volumeClaimSpec:" in text
    assert "config:" in text
    assert "sample:" in text
    assert "base-url:" not in text
    assert "ntfy.__ZONE_NAME__" not in text


def test_ntfy_argocd_app_is_an_applicationset():
    text = NTFY_APP.read_text(encoding="utf-8")
    assert "kind: ApplicationSet" in text
    assert "name: ntfy-set" in text
    assert "sample:" in text
    assert "base-url:" in text
    assert 'ntfy.{{index .metadata.annotations "twinbox.io/public-zone-name"}}' in text


def test_ntfy_step_replaces_existing_applicationset_before_apply():
    text = (
        REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-ntfy" / "run.sh"
    ).read_text(encoding="utf-8")
    assert "kubectl delete application ntfy -n argocd --ignore-not-found=true" in text
    assert "kubectl delete applicationset ntfy-set -n argocd --ignore-not-found=true" in text
    assert '--application "ntfy"' in text


def test_ntfy_ingressroute_exposes_ui():
    text = NTFY_INGRESSROUTE.read_text(encoding="utf-8")
    assert "kind: IngressRoute" in text
    assert "Host(`ntfy.__ZONE_NAME__`)" in text
    assert "name: ntfy" in text
    assert "port: 80" in text
    assert "webwiredoor" not in text


def test_argocd_ingressroute_uses_https_backend():
    text = ARGOCD_INGRESSROUTE.read_text(encoding="utf-8")
    assert "kind: IngressRoute" in text
    assert "Host(`argocd.__ZONE_NAME__`)" in text
    assert "name: argocd-server" in text
    assert "port: 443" in text
    assert "scheme: https" in text
    assert "serversTransport: argocd-server-transport" in text
    assert "websecure" in text


def test_argocd_servers_transport_disables_backend_cert_verification():
    text = ARGOCD_SERVER_TRANSPORT.read_text(encoding="utf-8")
    assert "kind: ServersTransport" in text
    assert "name: argocd-server-transport" in text
    assert "namespace: argocd" in text
    assert "insecureSkipVerify: true" in text


def test_grafana_values_includes_sidecar_and_datasources():
    text = GRAFANA_VALUES.read_text(encoding="utf-8")
    assert "existingSecret: grafana-oidc" in text
    assert "sidecar:" in text
    assert "datasources:" in text
    assert "enabled: true" in text
    assert "name: Prometheus" in text
    assert "name: Loki" in text
    assert "type: prometheus" in text
    assert "type: loki" in text
    assert "url: http://tempo.monitoring.svc.cluster.local:3200" in text
    assert (REPO_ROOT / "gitops" / "values" / "tempo.yaml").read_text(encoding="utf-8").count(
        "http_listen_port: 3200"
    ) == 1
    assert "root_url:" not in text


def test_grafana_argocd_app_is_an_applicationset():
    text = GRAFANA_APP.read_text(encoding="utf-8")
    assert "kind: ApplicationSet" in text
    assert "name: grafana-set" in text
    assert "root_url:" in text
    assert 'grafana.{{index .metadata.annotations "twinbox.io/public-zone-name"}}' in text


def test_homepage_configmap_is_not_part_of_the_core_platform_overlay():
    assert not (REPO_ROOT / "gitops" / "platform" / "homepage").exists()


def test_kustomization_includes_monitoring_resources():
    text = KUSTOMIZATION.read_text(encoding="utf-8")
    assert "argocd/argocd-cm.yaml" in text
    assert "argocd/argocd-wiredoor.yaml" not in text
    assert "authentik/ingressroute.yaml" in text
    assert "hubble/ingressroute.yaml" in text
    assert "traefik/traefik-podmonitor.yaml" not in text
    assert "management-consoles/proxmox-ingressroute.yaml" in text
    assert "pgadmin4/namespace.yaml" not in text
    assert "prometheus/ingressroute.yaml" not in text
    assert "prometheus/alertmanager-config.yaml" not in text
    assert "prometheus/cluster-health-alerts.yaml" not in text
    assert "prometheus/pvc-usage-alerts.yaml" not in text
    assert "traefik-manager/ingressroute.yaml" not in text
    assert "traefik-manager/deployment.yaml" not in text
    assert "ntfy/ingressroute.yaml" not in text
    assert "cluster-config/configmap.yaml" not in text
    assert "cluster-config/externalsecret.yaml" not in text
    assert "replacements:" not in text
    assert "data.ARGOCD_MATCH" not in text
    assert "data.HEADLAMP_MATCH" not in text
    assert "data.HOMEPAGE_BOOKMARKS_YAML" not in text


def test_prometheus_step_applies_kube_prometheus_stack():
    text = PROMETHEUS_STEP_MANIFEST.read_text(encoding="utf-8")
    run_text = PROMETHEUS_STEP_SCRIPT.read_text(encoding="utf-8")
    script_text = _prometheus_script_text()
    app_text = (REPO_ROOT / "gitops" / "apps" / "prometheus.yaml").read_text(encoding="utf-8")
    manifests_text = (
        REPO_ROOT / "gitops" / "apps" / "prometheus" / "manifests" / "kustomization.yaml"
    ).read_text(encoding="utf-8")
    prometheus_manifests_text = PROMETHEUS_MANIFESTS_KUSTOMIZATION.read_text(encoding="utf-8")

    assert "id: install-prometheus" in text
    assert "title: Install Prometheus" in text
    assert "kube-prometheus-stack" in text
    assert "Prometheus, Alertmanager, node-exporter, and kube-state-metrics" in text
    assert "script: categories/talos-cluster/steps/install-prometheus/run.sh" in text
    assert ': "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"' in run_text
    assert "install-prometheus.sh" in run_text
    assert '--application "prometheus"' in script_text
    assert '--destination-namespace "monitoring"' in script_text
    assert "gitops/apps/prometheus.yaml" in script_text
    assert "path: gitops/apps/prometheus/manifests" in app_text
    assert "cluster-health-alerts.yaml" in manifests_text
    assert "pvc-usage-alerts.yaml" in manifests_text
    assert "traefik-podmonitor.yaml" in prometheus_manifests_text


def test_reconcile_observability_script_accepts_cluster_kubeconfig_fallback():
    script_text = RECONCILE_OBSERVABILITY_SCRIPT.read_text(encoding="utf-8")

    assert ': "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"' in script_text
    assert ': "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"' not in script_text
    assert "cluster_kubeconfig_file" in script_text
    assert (
        'kubeconfig_file="${KUBECONFIG_FILE:-${TWINBOX_KUBECONFIG_FILE:-$cluster_kubeconfig_file}}"'
        in script_text
    )
    assert 'export KUBECONFIG_FILE="$kubeconfig_file"' in script_text
    assert 'export KUBECONFIG="$kubeconfig_file"' in script_text
    assert "kubeconfig not found at ${kubeconfig_file}" in script_text


def test_traefik_manager_step_deploys_browser_ui():
    assert not TRAEFIK_MANAGER_STEP_MANIFEST.exists()
    assert not TRAEFIK_MANAGER_STEP_SCRIPT.exists()
    script_text = _traefik_manager_script_text()

    assert "authentik-auth.sh" in script_text
    assert "openbao-secret-sync.sh" in script_text
    assert "Provisioning Authentik proxy application for Traefik Manager" in script_text
    assert "Traefik Manager" in script_text
    assert "outpost.goauthentik.io/auth/traefik" not in script_text
    assert (
        "kubectl delete application traefik-manager -n argocd --ignore-not-found=true"
        not in script_text
    )
    assert '--application "platform-ingress"' not in script_text
    assert "gitops/apps/platform-ingress.yaml" not in script_text
    assert 'platform_dir="$WORKSPACE_ROOT/gitops/platform-apps/traefik-manager"' in script_text
    assert 'kubectl apply -f "$platform_dir/namespace.yaml"' in script_text
    assert 'kubectl apply -f "$platform_dir/serviceaccount.yaml"' in script_text
    assert 'kubectl apply -f "$platform_dir/pvc.yaml"' in script_text
    assert 'kubectl apply -f "$platform_dir/service.yaml"' in script_text
    assert 'kubectl apply -f "$rendered_callback_ingressroute"' in script_text
    assert "cluster-public-zone.sh" in script_text
    assert 'sed "s/__ZONE_NAME__/${public_zone_name}/g"' in script_text
    assert 'mktemp "${TMPDIR:-/tmp}/traefik-manager-deployment-XXXXXX"' in script_text
    assert 'mktemp "${TMPDIR:-/tmp}/traefik-manager-ingressroute-XXXXXX"' in script_text
    assert 'mktemp "${TMPDIR:-/tmp}/traefik-manager-authentik-callback-XXXXXX"' in script_text
    assert ': "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"' in script_text
    assert "twinbox_public_zone_name" in script_text


def test_argocd_cluster_secret_helper_writes_runtime_projection():
    text = (REPO_ROOT / "scripts" / "manager" / "upsert-argocd-cluster-secret.sh").read_text(
        encoding="utf-8"
    )

    assert "argocd-manager-cluster-admin" in text
    assert "twinbox.io/domain-ready" in text
    assert "twinbox.io/public-zone-name" in text
    assert "twinbox.io/pod-cidr" in text
    assert "twinbox.io/resource-profile" in text
    assert "--resource-profile" in text
    assert "argocd.argoproj.io/secret-type" in text
    assert "create token argocd-manager" in text
    assert "tlsClientConfig" in text
    assert "existing_labels" in text
    assert "existing_annotations" in text


def test_argocd_cluster_secret_helper_resolves_pod_cidr_before_rendering_annotations():
    text = (REPO_ROOT / "scripts" / "manager" / "upsert-argocd-cluster-secret.sh").read_text(
        encoding="utf-8"
    )

    assert "10.244.0.0/16" not in text
    assert "Could not determine pod CIDR from cluster nodes; pass --pod-cidr explicitly" in text


def test_argocd_cluster_secret_helper_preserves_existing_resource_profile():
    text = (REPO_ROOT / "scripts" / "manager" / "upsert-argocd-cluster-secret.sh").read_text(
        encoding="utf-8"
    )

    assert 'RESOURCE_PROFILE="$(' in text
    assert '.["twinbox.io/resource-profile"]' in text
    assert text.index('existing_secret_json="$(kubectl -n argocd get secret') < text.index(
        'if [[ -z "$RESOURCE_PROFILE" && -n "${STEP_CONTEXT_JSON:-}" ]]; then'
    )
    assert text.index('if [[ -z "$RESOURCE_PROFILE" ]]; then') < text.index(
        'RESOURCE_PROFILE="standard"'
    )


def test_optional_app_state_helper_labels_the_argocd_cluster_secret():
    text = (REPO_ROOT / "scripts" / "manager" / "set-optional-app-state.sh").read_text(
        encoding="utf-8"
    )

    assert "twinbox.io/app-" in text
    assert ".cluster.resource_profile // empty" in text
    assert '"twinbox.io/resource-profile=${RESOURCE_PROFILE}"' in text
    assert "enabled|disabled" in text
    assert "kubectl -n argocd label secret" in text


def test_optional_apps_root_and_redirected_manifests_are_present():
    root_text = (REPO_ROOT / "gitops" / "apps" / "optional-apps-root.yaml").read_text(
        encoding="utf-8"
    )
    jitsi_optional_text = (REPO_ROOT / "gitops" / "optional-apps" / "jitsi.yaml").read_text(
        encoding="utf-8"
    )
    opencloud_optional_text = (REPO_ROOT / "gitops" / "optional-apps" / "opencloud.yaml").read_text(
        encoding="utf-8"
    )
    nextcloud_optional_text = NEXTCLOUD_OPTIONAL_APP.read_text(encoding="utf-8")
    karakeep_optional_text = KARAKEEP_APP.read_text(encoding="utf-8")

    assert "name: optional-apps-root" in root_text
    assert "path: gitops/optional-apps" in root_text
    assert "repoURL: __REPO_URL__" in root_text
    assert "targetRevision: __TARGET_REVISION__" in root_text

    optional_manifests = sorted((REPO_ROOT / "gitops" / "optional-apps").glob("*.yaml"))
    assert optional_manifests
    for manifest in optional_manifests:
        text = manifest.read_text(encoding="utf-8")
        assert "__REPO_URL__" not in text, manifest
        assert "__TARGET_REVISION__" not in text, manifest
        assert "repoURL: https://github.com/harrywesterman/Twinbox.git" in text, manifest
        assert "targetRevision: main" in text, manifest

    assert "kind: ApplicationSet" in jitsi_optional_text
    assert 'twinbox.io/app-jitsi: "enabled"' in jitsi_optional_text
    assert "kind: ApplicationSet" in opencloud_optional_text
    assert 'twinbox.io/app-opencloud: "enabled"' in opencloud_optional_text
    assert "kind: ApplicationSet" in nextcloud_optional_text
    assert 'twinbox.io/app-nextcloud: "enabled"' in nextcloud_optional_text
    assert "path: gitops/platform-apps/nextcloud" in nextcloud_optional_text
    assert "path: gitops/databases/nextcloud" in nextcloud_optional_text
    assert "kind: ApplicationSet" in karakeep_optional_text
    assert 'twinbox.io/app-karakeep: "enabled"' in karakeep_optional_text
    assert "path: gitops/platform-apps/karakeep" in karakeep_optional_text


def test_forgejo_bootstrap_seeds_from_upstream_and_renders_github_defaults():
    bootstrap_text = (REPO_ROOT / "scripts" / "manager" / "bootstrap-forgejo.sh").read_text(
        encoding="utf-8"
    )
    promote_text = (REPO_ROOT / "scripts" / "manager" / "forgejo-promote-upstream.sh").read_text(
        encoding="utf-8"
    )

    assert (
        "TWINBOX_UPSTREAM_GIT_REPO_URL:-https://github.com/harrywesterman/Twinbox.git"
        in bootstrap_text
    )
    assert "TWINBOX_FORGEJO_SEED_SOURCE_DIR" in bootstrap_text
    assert 'seed_source="$(resolve_seed_source)"' in bootstrap_text
    assert 'seed_repo_if_needed "$REPO_ROOT"' not in bootstrap_text
    assert "docker compose exec -T -u git forgejo bash -lc" in bootstrap_text
    assert "docker compose exec -T forgejo sh -lc" not in bootstrap_text

    for text in (bootstrap_text, promote_text):
        assert "commit_rendered_changes()" in text
        assert 'commit_rendered_changes "$' in text
        assert 'github_repo_url = "https://github.com/harrywesterman/Twinbox.git"' in text
        assert "line = line.replace(github_repo_url, repo_url)" in text
        assert "targetRevision:" in text
        assert "__REPO_URL__" in text
        assert "__TARGET_REVISION__" in text

    assert '--force-with-lease forgejo "$promote_branch:refs/heads/$promote_branch"' in promote_text


def test_optional_database_apps_patch_cloudnativepg_requests_by_resource_profile():
    database_apps = [
        "hedgedoc",
        "immich",
        "n8n",
        "nextcloud",
        "openwebui",
        "outline",
        "paperless",
        "pixelfed",
        "vaultwarden",
    ]

    for app_name in database_apps:
        text = (REPO_ROOT / "gitops" / "optional-apps" / f"{app_name}.yaml").read_text(
            encoding="utf-8"
        )
        assert "twinbox.io/resource-profile" in text
        assert "path: /spec/resources/requests/cpu" in text
        assert "path: /spec/resources/requests/memory" in text
        assert f"name: {app_name}-db" in text


def test_dashy_appset_patches_requests_by_resource_profile():
    text = (REPO_ROOT / "gitops" / "apps" / "dashy.yaml").read_text(encoding="utf-8")

    assert "twinbox.io/resource-profile" in text
    assert "path: /spec/template/spec/containers/0/resources/requests/cpu" in text
    assert "path: /spec/template/spec/containers/0/resources/requests/memory" in text


def test_databases_kustomization_includes_authentik_resources():
    text = DATABASES_KUSTOMIZATION.read_text(encoding="utf-8")
    assert "shared/namespace.yaml" in text
    assert "longhorn-single-storageclass.yaml" in text
    assert "authentik/cluster.yaml" in text
    assert "authentik/externalsecret.yaml" in text
    assert "authentik/pooler-ro.yaml" in text
    assert "authentik/pooler-rw.yaml" in text
    assert "authentik/scheduled-backup.yaml" in text
    assert DATABASES_NAMESPACE.read_text(encoding="utf-8").startswith(
        "apiVersion: v1\nkind: Namespace\n"
    )


def test_databases_shared_kustomization_only_owns_namespace():
    text = DATABASES_SHARED_KUSTOMIZATION.read_text(encoding="utf-8")
    assert "namespace.yaml" in text
    assert "../namespace.yaml" not in text
    assert "longhorn-single-storageclass.yaml" not in text
    for app_name in [
        "authentik",
        "hedgedoc",
        "immich",
        "mastodon",
        "n8n",
        "nextcloud",
        "openwebui",
        "outline",
        "paperless",
        "pixelfed",
        "vaultwarden",
        "zulip",
    ]:
        assert f"{app_name}/" not in text


def test_databases_shared_namespace_manifest_is_canonical():
    text = DATABASES_NAMESPACE.read_text(encoding="utf-8")

    assert text.startswith("apiVersion: v1\nkind: Namespace\n")
    assert "  name: databases\n" in text
    assert "    app.kubernetes.io/part-of: twinbox\n" in text
    assert "    app.kubernetes.io/component: databases\n" in text
    assert not (REPO_ROOT / "gitops" / "databases" / "namespace.yaml").exists()


def test_database_namespace_direct_apply_scripts_use_shared_manifest():
    authentik_text = AUTHENTIK_STEP_SCRIPT.read_text(encoding="utf-8")
    zulip_text = (
        REPO_ROOT / "categories" / "apps" / "steps" / "install-zulip" / "run.sh"
    ).read_text(encoding="utf-8")

    for text in [authentik_text, zulip_text]:
        assert "gitops/databases/shared/namespace.yaml" in text
        assert "gitops/databases/namespace.yaml" not in text


def test_argocd_source_kustomizations_are_self_contained():
    for source_path in _argocd_source_paths_with_kustomizations():
        text = (REPO_ROOT / source_path / "kustomization.yaml").read_text(encoding="utf-8")
        assert "../" not in text, f"{source_path}/kustomization.yaml references a parent path"


def test_cloudnativepg_bootstrap_installs_shared_database_application():
    step_text = CLOUDNATIVEPG_STEP_SCRIPT.read_text(encoding="utf-8")
    app_text = DATABASES_APP.read_text(encoding="utf-8")

    assert "gitops/apps/cloudnativepg.yaml" in step_text
    assert "gitops/apps/databases.yaml" in step_text
    assert '--application "cloudnativepg"' in step_text
    assert '--application "databases"' in step_text
    assert "kind: Application" in app_text
    assert "name: databases" in app_text
    assert "path: gitops/databases/shared" in app_text
    assert "namespace: databases" in app_text
    assert "CreateNamespace=true" in app_text


def test_database_app_overlays_do_not_carry_namespace_manifests():
    for app_name in [
        "hedgedoc",
        "immich",
        "n8n",
        "nextcloud",
        "openwebui",
        "outline",
        "paperless",
        "pixelfed",
        "vaultwarden",
    ]:
        assert not (REPO_ROOT / "gitops" / "databases" / app_name / "namespace.yaml").exists()


def test_vaultwarden_manifests_use_postgresql_and_domain_limited_signups():
    deployment_text = (
        REPO_ROOT / "gitops" / "platform-apps" / "vaultwarden" / "deployment.yaml"
    ).read_text(encoding="utf-8")
    externalsecret_text = (
        REPO_ROOT / "gitops" / "platform-apps" / "vaultwarden" / "externalsecret.yaml"
    ).read_text(encoding="utf-8")
    db_externalsecret_text = (
        REPO_ROOT / "gitops" / "databases" / "vaultwarden" / "externalsecret.yaml"
    ).read_text(encoding="utf-8")
    cluster_text = (REPO_ROOT / "gitops" / "databases" / "vaultwarden" / "cluster.yaml").read_text(
        encoding="utf-8"
    )
    objectstore_text = (
        REPO_ROOT / "gitops" / "databases" / "vaultwarden" / "objectstore.yaml"
    ).read_text(encoding="utf-8")

    assert re.search(r"ghcr\.io/dani-garcia/vaultwarden:\d+\.\d+\.\d+", deployment_text)
    assert "ghcr.io/dani-garcia/vaultwarden:latest" not in deployment_text
    assert "SIGNUPS_DOMAINS_WHITELIST" in deployment_text
    assert "WEBSOCKET_ENABLED" in deployment_text
    assert "secretKeyRef:" in deployment_text
    assert "VAULTWARDEN_DATABASE_URL" in externalsecret_text
    assert "VAULTWARDEN_ADMIN_TOKEN" in externalsecret_text
    assert "VAULTWARDEN_POSTGRESQL__USERNAME" in db_externalsecret_text
    assert "VAULTWARDEN_POSTGRESQL__PASSWORD" in db_externalsecret_text
    assert "barmanObjectName: vaultwarden-db-objectstore" in cluster_text
    assert "destinationPath: s3://twinbox-velero/vaultwarden-db/" in objectstore_text


def test_pixelfed_manifests_use_postgresql_and_longhorn_storage():
    step_text = PIXELFED_STEP_SCRIPT.read_text(encoding="utf-8")
    deployment_text = (
        REPO_ROOT / "gitops" / "platform-apps" / "pixelfed" / "deployment.yaml"
    ).read_text(encoding="utf-8")
    workers_text = (REPO_ROOT / "gitops" / "platform-apps" / "pixelfed" / "workers.yaml").read_text(
        encoding="utf-8"
    )
    externalsecret_text = (
        REPO_ROOT / "gitops" / "platform-apps" / "pixelfed" / "externalsecret.yaml"
    ).read_text(encoding="utf-8")
    db_externalsecret_text = (
        REPO_ROOT / "gitops" / "databases" / "pixelfed" / "externalsecret.yaml"
    ).read_text(encoding="utf-8")
    cluster_text = (REPO_ROOT / "gitops" / "databases" / "pixelfed" / "cluster.yaml").read_text(
        encoding="utf-8"
    )
    objectstore_text = (
        REPO_ROOT / "gitops" / "databases" / "pixelfed" / "objectstore.yaml"
    ).read_text(encoding="utf-8")

    assert 'source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"' in step_text
    assert 'source "$WORKSPACE_ROOT/scripts/manager/authentik-auth.sh"' in step_text
    assert '--secret-name "pixelfed"' in step_text
    assert (
        '--required-keys "APP_KEY,PIXELFED_POSTGRESQL__USERNAME,PIXELFED_POSTGRESQL__PASSWORD,PF_OIDC_CLIENT_ID,PF_OIDC_CLIENT_SECRET,PF_OIDC_AUTHORIZE_URL,PF_OIDC_TOKEN_URL,PF_OIDC_PROFILE_URL,PF_OIDC_LOGOUT_URL"'
        in step_text
    )
    assert "apply-argocd-application.sh" in step_text
    assert '--application "pixelfed"' in step_text
    assert "gitops/apps/pixelfed.yaml" in step_text
    assert "php artisan instance:actor" in step_text
    assert "php artisan passport:keys --force" in step_text
    assert "Provisioning Authentik OIDC client for Pixelfed" in step_text

    assert (
        "ghcr.io/jippi/docker-pixelfed:nightly-2026-05-10-staging-apache-8.4-bookworm"
        in deployment_text
    )
    assert (
        "ghcr.io/jippi/docker-pixelfed:nightly-2026-05-10-staging-apache-8.4-bookworm"
        in workers_text
    )
    assert "APP_URL" in deployment_text
    assert "APP_DOMAIN" in deployment_text
    assert "DB_HOST" in deployment_text
    assert "pixelfed-db-pooler-rw-session.databases.svc.cluster.local" in deployment_text
    assert "pixelfed-redis" in deployment_text
    assert "AUTORUN_ENABLED" in deployment_text
    assert "PF_OIDC_ENABLED" in deployment_text
    assert "PF_OIDC_ENABLED" in workers_text
    assert "PF_OIDC_CLIENT_ID" in deployment_text
    assert "PF_OIDC_CLIENT_SECRET" in deployment_text
    assert "PF_OIDC_AUTHORIZE_URL" in deployment_text
    assert "PF_OIDC_TOKEN_URL" in deployment_text
    assert "PF_OIDC_PROFILE_URL" in deployment_text
    assert "PF_OIDC_LOGOUT_URL" in deployment_text
    assert "- horizon" in workers_text
    assert "- schedule:work" in workers_text
    assert "name: pixelfed-bootstrap" in externalsecret_text
    assert "secretKey: APP_KEY" in externalsecret_text
    assert "property: APP_KEY" in externalsecret_text
    assert "property: PIXELFED_POSTGRESQL__USERNAME" in externalsecret_text
    assert "property: PIXELFED_POSTGRESQL__PASSWORD" in externalsecret_text
    assert "property: PF_OIDC_CLIENT_ID" in externalsecret_text
    assert "property: PF_OIDC_CLIENT_SECRET" in externalsecret_text
    assert "property: PF_OIDC_AUTHORIZE_URL" in externalsecret_text
    assert "property: PF_OIDC_TOKEN_URL" in externalsecret_text
    assert "property: PF_OIDC_PROFILE_URL" in externalsecret_text
    assert "property: PF_OIDC_LOGOUT_URL" in externalsecret_text
    assert "property: PIXELFED_POSTGRESQL__USERNAME" in db_externalsecret_text
    assert "property: PIXELFED_POSTGRESQL__PASSWORD" in db_externalsecret_text
    assert "barmanObjectName: pixelfed-db-objectstore" in cluster_text
    assert "destinationPath: s3://twinbox-velero/pixelfed-db/" in objectstore_text


def test_paperless_redis_manifest_runs_statelessly():
    redis_text = (REPO_ROOT / "gitops" / "platform-apps" / "paperless" / "redis.yaml").read_text(
        encoding="utf-8"
    )

    assert "name: paperless-redis" in redis_text
    assert "emptyDir: {}" in redis_text
    assert "--appendonly" in redis_text
    assert '- "no"' in redis_text
    assert "--save" in redis_text
    assert 'value: "60"' not in redis_text


def test_paperless_storage_manifest_keeps_app_pvcs_only():
    pvc_text = (REPO_ROOT / "gitops" / "platform-apps" / "paperless" / "pvc.yaml").read_text(
        encoding="utf-8"
    )

    assert "name: paperless-data" in pvc_text
    assert "name: paperless-media" in pvc_text
    assert "name: paperless-consume" in pvc_text
    assert "name: paperless-export" in pvc_text
    assert "paperless-redis-data" not in pvc_text


def test_paperless_deployment_uses_reasonable_resources():
    deployment_text = (
        REPO_ROOT / "gitops" / "platform-apps" / "paperless" / "deployment.yaml"
    ).read_text(encoding="utf-8")

    assert "resources:" in deployment_text
    assert "memory: 512Mi" in deployment_text
    assert "memory: 1Gi" in deployment_text
    assert "cpu: 250m" in deployment_text
    assert 'cpu: "1"' in deployment_text
    assert "failureThreshold: 120" in deployment_text


def test_cnpg_database_clusters_have_seaweedfs_backups():
    authentik_cluster_text = (
        REPO_ROOT / "gitops" / "databases" / "authentik" / "cluster.yaml"
    ).read_text(encoding="utf-8")
    authentik_objectstore_text = (
        REPO_ROOT / "gitops" / "databases" / "authentik" / "objectstore.yaml"
    ).read_text(encoding="utf-8")
    immich_cluster_text = (
        REPO_ROOT / "gitops" / "databases" / "immich" / "cluster.yaml"
    ).read_text(encoding="utf-8")
    immich_objectstore_text = (
        REPO_ROOT / "gitops" / "databases" / "immich" / "objectstore.yaml"
    ).read_text(encoding="utf-8")
    backup_secret_text = (
        REPO_ROOT / "gitops" / "databases" / "shared" / "seaweedfs-backup-credentials.yaml"
    ).read_text(encoding="utf-8")

    assert "barmanObjectName: authentik-db-objectstore" in authentik_cluster_text
    assert "serverName: authentik-db" in authentik_cluster_text
    assert "destinationPath: s3://twinbox-velero/authentik-db/" in authentik_objectstore_text
    assert (
        "endpointURL: http://seaweedfs.longhorn-system.svc.cluster.local:8333"
        in authentik_objectstore_text
    )
    assert "name: seaweedfs-backup-credentials" in authentik_objectstore_text
    assert "key: AWS_ACCESS_KEY_ID" in authentik_objectstore_text
    assert "key: AWS_SECRET_ACCESS_KEY" in authentik_objectstore_text

    assert "barmanObjectName: immich-db-objectstore" in immich_cluster_text
    assert "serverName: immich-db" in immich_cluster_text
    assert "destinationPath: s3://twinbox-velero/immich-db/" in immich_objectstore_text
    assert (
        "endpointURL: http://seaweedfs.longhorn-system.svc.cluster.local:8333"
        in immich_objectstore_text
    )
    assert "name: seaweedfs-backup-credentials" in immich_objectstore_text
    assert "key: AWS_ACCESS_KEY_ID" in immich_objectstore_text
    assert "key: AWS_SECRET_ACCESS_KEY" in immich_objectstore_text

    assert "name: seaweedfs-backup-credentials" in backup_secret_text
    assert "twinbox/global/velero" in backup_secret_text
    assert "property: username" in backup_secret_text
    assert "property: password" in backup_secret_text


def test_install_secret_sync_also_populates_seaweedfs_backup_credentials():
    text = INSTALL_SECRET_SYNC_SCRIPT.read_text(encoding="utf-8")

    assert "velero.json" in text
    assert "Syncing SeaweedFS/Velero credentials to OpenBao" in text
    assert 'openbao_sync_global_secret_file "$VELERO_SECRET_NAME"' in text
    assert '"mode" "endpoint" "bucket" "region" "username" "password"' in text
    assert "velero_secret_name" in text


def test_loki_and_openbao_longhorn_sizes_are_right_sized():
    loki_values_text = (REPO_ROOT / "gitops" / "values" / "loki.yaml").read_text(encoding="utf-8")
    openbao_values_text = (REPO_ROOT / "gitops" / "values" / "openbao.yaml").read_text(
        encoding="utf-8"
    )

    assert "size: 10Gi" in loki_values_text
    assert "storageClass: longhorn-single" in loki_values_text
    assert "storageClassName: longhorn-single" not in loki_values_text
    assert "size: 5Gi" not in loki_values_text
    assert "size: 10Gi" in openbao_values_text
    assert "storageClass: longhorn-single" in openbao_values_text
    assert "size: 2Gi" not in openbao_values_text


def test_authentik_db_cluster_is_scaled_for_ha_capacity_without_storage_replication():
    text = AUTHENTIK_DB_CLUSTER.read_text(encoding="utf-8")
    assert "instances: 3" in text
    assert "size: 20Gi" in text
    assert "storageClass: longhorn-single" in text


def test_critical_cnpg_clusters_use_ha_instances_with_single_replica_storage():
    for name in (
        "authentik",
        "n8n",
        "zulip",
        "paperless",
        "vaultwarden",
        "immich",
    ):
        text = (REPO_ROOT / "gitops" / "databases" / name / "cluster.yaml").read_text(
            encoding="utf-8"
        )
        assert "instances: 3" in text
        assert "storageClass: longhorn-single" in text

    pixelfed_cluster_text = (
        REPO_ROOT / "gitops" / "databases" / "pixelfed" / "cluster.yaml"
    ).read_text(encoding="utf-8")
    assert "instances: 2" in pixelfed_cluster_text
    assert "storageClass: longhorn-single" in pixelfed_cluster_text


def test_database_app_installers_refresh_pgadmin_after_database_ready():
    expectations = {
        "install-hedgedoc": (
            "hedgedoc",
            "hedgedoc-db-pooler-rw-session.databases.svc.cluster.local",
        ),
        "install-immich": ("immich", "immich-db-pooler-rw-session.databases.svc.cluster.local"),
        "install-mastodon": (
            "mastodon",
            "mastodon-db-pooler-rw-session.databases.svc.cluster.local",
        ),
        "install-n8n": ("n8n", "n8n-db-pooler-rw-session.databases.svc.cluster.local"),
        "install-nextcloud": ("nextcloud", "nextcloud-db-pooler-rw.databases.svc.cluster.local"),
        "install-openwebui": (
            "openwebui",
            "openwebui-db-pooler-rw-session.databases.svc.cluster.local",
        ),
        "install-outline": ("outline", "outline-db-pooler-rw-session.databases.svc.cluster.local"),
        "install-paperless": ("paperless", "paperless-db-pooler-rw.databases.svc.cluster.local"),
        "install-pixelfed": (
            "pixelfed",
            "pixelfed-db-pooler-rw-session.databases.svc.cluster.local",
        ),
        "install-vaultwarden": (
            "vaultwarden",
            "vaultwarden-db-pooler-rw.databases.svc.cluster.local",
        ),
        "install-zulip": ("zulip", "zulip-db-pooler-rw.databases.svc.cluster.local"),
    }

    assert PGADMIN_SYNC_SERVER_SCRIPT.read_text(encoding="utf-8").startswith("#!/usr/bin/env bash")

    for step_id, (app_id, host) in expectations.items():
        text = (REPO_ROOT / "categories" / "apps" / "steps" / step_id / "run.sh").read_text(
            encoding="utf-8"
        )
        assert "sync-pgadmin4-server.sh" in text
        assert f'--app-id "{app_id}"' in text
        assert f'--host "{host}"' in text


def test_nextcloud_db_cluster_uses_future_install_capacity():
    text = (REPO_ROOT / "gitops" / "databases" / "nextcloud" / "cluster.yaml").read_text(
        encoding="utf-8"
    )
    assert "instances: 2" in text
    assert "storageClass: longhorn-single" in text


def test_authentik_db_storageclass_uses_single_replica():
    text = AUTHENTIK_DB_STORAGECLASS.read_text(encoding="utf-8")
    assert "name: longhorn-single" in text
    assert 'numberOfReplicas: "1"' in text
    assert "provisioner: driver.longhorn.io" in text


def test_install_immich_step_applies_its_argo_application():
    text = (REPO_ROOT / "categories" / "apps" / "steps" / "install-immich" / "run.sh").read_text(
        encoding="utf-8"
    )
    assert (
        'immich_rendered_manifest="$(mktemp "${TMPDIR:-/tmp}/immich-application-XXXXXX")"' in text
    )
    assert "gitops/apps/immich.yaml" in text
    assert "gitops/platform-apps/immich/db-externalsecret.yaml" not in text
    assert "gitops/databases/immich/cluster.yaml" not in text
    assert "gitops/databases/immich/externalsecret.yaml" not in text
    assert "gitops/databases/immich/pooler-ro.yaml" not in text
    assert "gitops/databases/immich/pooler-rw.yaml" not in text
    assert "gitops/databases/immich/scheduled-backup.yaml" not in text
    assert (
        'kubectl apply -f "$WORKSPACE_ROOT/gitops/platform-apps/immich/namespace.yaml"' not in text
    )
    assert 'kubectl apply -f "$WORKSPACE_ROOT/gitops/platform-apps/immich/pvc.yaml"' not in text
    assert (
        'kubectl apply -f "$WORKSPACE_ROOT/gitops/platform-apps/immich/externalsecret.yaml"'
        not in text
    )
    assert 'kubectl apply -f "$immich_app_db_externalsecret_manifest"' not in text
    assert 'kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/namespace.yaml"' not in text
    assert 'kubectl apply -f "$databases_namespace_manifest"' not in text
    assert 'wait_for_resources_ready "databases"' not in text
    assert 'wait_for_deployment_rollout "immich"' not in text
    assert (
        'search_response="$(authentik_api_get "/providers/oauth2/?search=${provider_name// /%20}&page_size=50")"'
        in text
    )
    assert "render_template() {" in text
    assert "render_template \\" in text
    assert '--manifest "$immich_rendered_manifest"' in text
    assert '--application "immich"' in text
    assert '--destination-namespace "immich"' in text
    db_externalsecret_text = (
        REPO_ROOT / "gitops" / "platform-apps" / "immich" / "db-externalsecret.yaml"
    ).read_text(encoding="utf-8")
    assert "name: immich-db-credentials" in db_externalsecret_text
    assert "namespace: immich" in db_externalsecret_text
    assert "secretStoreRef:" in db_externalsecret_text
    assert "name: openbao" in db_externalsecret_text
    assert "twinbox/global/immich" in db_externalsecret_text
    immich_app_text = _immich_app_text()
    assert "path: gitops/platform-apps/immich" in immich_app_text
    assert "path: gitops/databases/immich" in immich_app_text
    assert "db-externalsecret.yaml" in (
        REPO_ROOT / "gitops" / "platform-apps" / "immich" / "kustomization.yaml"
    ).read_text(encoding="utf-8")


def test_mastodon_step_applies_the_custom_app_and_bootstraps_admin_access():
    step_text = MASTODON_STEP_SCRIPT.read_text(encoding="utf-8")
    step_manifest_text = MASTODON_STEP_MANIFEST.read_text(encoding="utf-8")
    app_text = MASTODON_APP.read_text(encoding="utf-8")
    values_text = MASTODON_VALUES.read_text(encoding="utf-8")
    namespace_text = MASTODON_NAMESPACE.read_text(encoding="utf-8")
    runtime_secret_text = MASTODON_RUNTIME_SECRET.read_text(encoding="utf-8")
    s3_secret_text = MASTODON_S3_SECRET.read_text(encoding="utf-8")
    db_secret_text = MASTODON_DB_SECRET.read_text(encoding="utf-8")
    db_cluster_text = MASTODON_DB_CLUSTER.read_text(encoding="utf-8")
    db_objectstore_text = MASTODON_DB_OBJECTSTORE.read_text(encoding="utf-8")
    dashy_config_text = (REPO_ROOT / "lib" / "dashy-config.mjs").read_text(encoding="utf-8")

    assert "title: Install Mastodon" in step_manifest_text
    assert "icon: install-mastodon" in step_manifest_text
    assert "categories/apps/steps/install-mastodon/run.sh" in step_manifest_text

    generate_alphanumeric_text = step_text.split("generate_alphanumeric() {", 1)[1].split(
        "generate_vapid_keys() {", 1
    )[0]
    assert 'node - "$length"' in generate_alphanumeric_text
    assert "head -c" not in generate_alphanumeric_text

    assert 'source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"' in step_text
    assert 'source "$WORKSPACE_ROOT/scripts/manager/authentik-auth.sh"' in step_text
    assert "openbao_read_global_secret_json mastodon" in step_text
    assert "mastodon_secret_file=" in step_text
    assert 'mastodon_admin_password=""' in step_text
    assert "sync-openbao-global-secret.sh" in step_text
    assert '--secret-name "mastodon"' in step_text
    assert (
        '--required-keys "MASTODON_POSTGRESQL__USERNAME,MASTODON_POSTGRESQL__PASSWORD,REDIS_PASSWORD,SECRET_KEY_BASE,OTP_SECRET,VAPID_PRIVATE_KEY,VAPID_PUBLIC_KEY,ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY,ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY,ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT,MASTODON_OIDC_CLIENT_ID,MASTODON_OIDC_CLIENT_SECRET,MASTODON_ADMIN_USERNAME"'
        in step_text
    )
    assert (
        '--required-keys "MASTODON_POSTGRESQL__USERNAME,MASTODON_POSTGRESQL__PASSWORD,REDIS_PASSWORD,SECRET_KEY_BASE,OTP_SECRET,VAPID_PRIVATE_KEY,VAPID_PUBLIC_KEY,ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY,ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY,ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT,MASTODON_OIDC_CLIENT_ID,MASTODON_OIDC_CLIENT_SECRET,MASTODON_ADMIN_USERNAME,MASTODON_ADMIN_PASSWORD"'
        in step_text
    )
    assert "gitops/platform-apps/mastodon/namespace.yaml" in step_text
    assert "gitops/databases/shared/namespace.yaml" in step_text
    assert "gitops/platform-apps/mastodon/externalsecret-runtime.yaml" in step_text
    assert "gitops/platform-apps/mastodon/externalsecret-s3.yaml" in step_text
    assert "gitops/databases/mastodon/externalsecret.yaml" in step_text
    assert 'openbao_wait_for_external_secret_ready "mastodon" "mastodon-runtime"' in step_text
    assert 'openbao_wait_for_secret "mastodon-runtime" "mastodon"' in step_text
    assert (
        'openbao_wait_for_external_secret_ready "databases" "mastodon-db-credentials"' in step_text
    )
    assert 'openbao_wait_for_secret "mastodon-db-credentials" "databases"' in step_text
    assert "render_template" in step_text
    assert "gitops/apps/mastodon.yaml" in step_text
    assert "apply-argocd-application.sh" in step_text
    assert '--application "mastodon"' in step_text
    assert "wait_for_deployment_image" in step_text
    assert "bundle" in step_text
    assert "db:migrate db:seed" in step_text
    assert "SKIP_POST_DEPLOYMENT_MIGRATIONS" not in step_text
    assert 'kubectl -n mastodon logs "job/' in step_text
    assert "kubectl -n mastodon exec deployment/mastodon-web" in step_text
    assert "bin/tootctl" in step_text
    assert (
        'accounts modify "$mastodon_admin_username" --approve --confirm --role Owner' in step_text
    )
    assert (
        'accounts create "$mastodon_admin_username" --email "$mastodon_admin_email" --confirmed --role Owner --approve'
        in step_text
    )
    assert "sync-pgadmin4-server.sh" in step_text
    assert '--app-id "mastodon"' in step_text
    assert '--host "mastodon-db-pooler-rw-session.databases.svc.cluster.local"' in step_text
    assert "ensure-netbird-service.sh" in step_text
    assert '--service-name "mastodon"' in step_text
    assert '--service-domain "mastodon.${public_zone_name}"' in step_text
    assert "path: gitops/platform-apps/mastodon" in app_text
    assert "path: gitops/databases/mastodon" in app_text
    assert "mastodon.__ZONE_NAME__" in app_text
    assert "authentik.__ZONE_NAME__/application/o/mastodon/" in app_text
    assert "Host(`mastodon.__ZONE_NAME__`)" in app_text
    assert "mastodon-db-pooler-rw-session.databases.svc.cluster.local" in values_text
    assert "mastodon-redis.mastodon.svc.cluster.local" in values_text
    assert "elasticsearch:\n  enabled: false" in values_text
    assert "dbMigrate:\n      enabled: false" in values_text
    assert "pod-security.kubernetes.io/enforce: baseline" in namespace_text
    assert "pod-security.kubernetes.io/audit: baseline" in namespace_text
    assert "pod-security.kubernetes.io/warn: baseline" in namespace_text
    assert "mastodon-runtime" in runtime_secret_text
    assert "property: MASTODON_POSTGRESQL__PASSWORD" in runtime_secret_text
    assert "property: REDIS_PASSWORD" in runtime_secret_text
    assert "property: SECRET_KEY_BASE" in runtime_secret_text
    assert "property: OTP_SECRET" in runtime_secret_text
    assert "property: VAPID_PRIVATE_KEY" in runtime_secret_text
    assert "property: VAPID_PUBLIC_KEY" in runtime_secret_text
    assert "property: ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" in runtime_secret_text
    assert "property: ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY" in runtime_secret_text
    assert "property: ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT" in runtime_secret_text
    assert "name: mastodon-s3" in s3_secret_text
    assert "key: twinbox/global/velero" in s3_secret_text
    assert "name: mastodon-db-credentials" in db_secret_text
    assert "property: MASTODON_POSTGRESQL__USERNAME" in db_secret_text
    assert "property: MASTODON_POSTGRESQL__PASSWORD" in db_secret_text
    assert "barmanObjectName: mastodon-db-objectstore" in db_cluster_text
    assert "instances: 2" in db_cluster_text
    assert "cpu: 100m" in db_cluster_text
    assert "memory: 256Mi" in db_cluster_text
    assert "cpu: 500m" in db_cluster_text
    assert "memory: 1Gi" in db_cluster_text
    assert "destinationPath: s3://twinbox-velero/mastodon-db/" in db_objectstore_text
    assert "imageName: ghcr.io/cloudnative-pg/postgresql:16.4" in db_cluster_text
    assert '["install-mastodon", "install-mastodon"]' in dashy_config_text
    assert '["Mastodon", "install-mastodon"]' in dashy_config_text
    immich_db_text = IMMICH_DB_KUSTOMIZATION.read_text(encoding="utf-8")
    assert "namespace.yaml" not in immich_db_text
    assert "../namespace.yaml" not in immich_db_text
    assert not (REPO_ROOT / "gitops" / "databases" / "immich" / "namespace.yaml").exists()
    assert DATABASES_NAMESPACE.read_text(encoding="utf-8").startswith(
        "apiVersion: v1\nkind: Namespace\n"
    )


def test_immich_values_keep_valkey_storageclass_nested():
    text = (REPO_ROOT / "gitops" / "values" / "immich.yaml").read_text(encoding="utf-8")
    assert "          tag: v3.0.0" in text
    assert "valkey:" in text
    assert "      storageClass: longhorn" in text
    assert "\n    storageClass: longhorn\n" not in text


def test_install_nextcloud_step_uses_its_own_manifests_and_oidc_bootstrap():
    text = (REPO_ROOT / "categories" / "apps" / "steps" / "install-nextcloud" / "run.sh").read_text(
        encoding="utf-8"
    )
    optional_app_text = NEXTCLOUD_OPTIONAL_APP.read_text(encoding="utf-8")

    assert "gitops/optional-apps/nextcloud.yaml" in text
    assert 'bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \\' in text
    assert '--manifest "$WORKSPACE_ROOT/gitops/optional-apps/nextcloud.yaml"' in text
    assert "Syncing Nextcloud bootstrap secret to OpenBao" in text
    assert "nextcloud-db-pooler-rw.databases.svc.cluster.local" in text
    assert 'kubectl apply -f "$nextcloud_platform_dir/namespace.yaml"' not in text
    assert "nextcloud_db_cluster_manifest" not in text
    assert "nextcloud_rendered_app_manifest" not in text
    assert "__NEXTCLOUD_VALUES__" not in text
    assert "gitops/apps/nextcloud.yaml" not in text
    assert "gitops/databases/namespace.yaml" not in text
    assert "user_oidc:provider" in text
    assert "nextcloud" in text
    assert "config:system:set trusted_domains 1" in text
    assert "authentik_resolve_signing_key_id" in text
    assert '--arg signing_key "$signing_key_id"' in text
    assert "signing_key: $signing_key" in text
    assert "oidc_groups_mapping_release_url" in text
    assert "app:enable -f oidc_groups_mapping" in text
    assert "oidc-groups:set" in text
    assert "admins-to-admin" in text
    assert r"tmp_dir=\"\$(mktemp -d)\"" in text
    assert "trap 'rm -rf \\\"\\$tmp_dir\\\"' EXIT" in text
    assert '\\"claimPath\\": \\"groups\\"' in text
    assert '\\"admins\\": \\"admin\\"' in text
    assert "--group-provisioning='1'" in text
    assert "config:app:set --type=string --value=1 user_oidc provider-1-groupProvisioning" in text
    assert "NEXTCLOUD_OIDC_REDIRECT_URI_PRETTY" in text
    assert "NEXTCLOUD_OIDC_LOGOUT_URI_PRETTY" in text
    assert "NEXTCLOUD_OIDC_BACKCHANNEL_URI_PRETTY" in text
    assert "redirect_login_pretty" in text
    assert "redirect_logout_pretty" in text
    assert "redirect_backchannel_pretty" in text
    assert "apps/user_oidc/code" in text
    assert (
        "config:system:set wopi_url --value='https://nextcloud-collabora.${public_zone_name}'"
        in text
    )
    assert (
        "config:app:set --value='https://nextcloud-collabora.${public_zone_name}' richdocuments wopi_url"
        in text
    )
    assert "richdocuments:activate-config" in text
    assert "Could not resolve Authentik signing key ID for ${AUTHENTIK_SIGNING_KEY_NAME}" in text
    assert "exec /cron.sh" in (REPO_ROOT / "gitops" / "values" / "nextcloud.yaml").read_text(
        encoding="utf-8"
    )
    assert "kind: ApplicationSet" in optional_app_text
    assert "name: nextcloud-set" in optional_app_text
    assert 'twinbox.io/app-nextcloud: "enabled"' in optional_app_text
    assert re.search(r'targetRevision:\s*"\d+\.\d+\.\d+"', optional_app_text)
    assert "path: gitops/platform-apps/nextcloud" in optional_app_text
    assert "path: gitops/databases/nextcloud" in optional_app_text
    assert "name: nextcloud-well-known-redirect" in optional_app_text
    assert "name: nextcloud-db" in optional_app_text


def test_hedgedoc_database_cluster_is_right_sized_for_current_capacity():
    text = (REPO_ROOT / "gitops" / "databases" / "hedgedoc" / "cluster.yaml").read_text(
        encoding="utf-8"
    )
    objectstore_text = (
        REPO_ROOT / "gitops" / "databases" / "hedgedoc" / "objectstore.yaml"
    ).read_text(encoding="utf-8")

    assert "name: hedgedoc-db" in text
    assert "instances: 2" in text
    assert "storageClass: longhorn-single" in text
    assert "cpu: 100m" in text
    assert "memory: 256Mi" in text
    assert 'cpu: "500m"' in text
    assert "memory: 512Mi" in text
    assert 'shared_buffers: "64MB"' in text
    assert 'effective_cache_size: "192MB"' in text
    assert "barmanObjectName: hedgedoc-db-objectstore" in text
    assert "s3://twinbox-velero/hedgedoc-db/" in objectstore_text
    assert "bootstrap:" in text
    assert "secret:" in text
    assert "name: hedgedoc-db-credentials" in text


def test_authentik_values_request_memory_for_server_and_worker():
    values = yaml.safe_load(
        (REPO_ROOT / "gitops" / "apps" / "authentik" / "values.yaml").read_text(encoding="utf-8")
    )

    assert values["global"]["topologySpreadConstraints"] == [
        {
            "maxSkew": 1,
            "topologyKey": "kubernetes.io/hostname",
            "whenUnsatisfiable": "DoNotSchedule",
        }
    ]
    assert values["server"]["livenessProbe"]["timeoutSeconds"] == 10
    assert values["server"]["readinessProbe"]["timeoutSeconds"] == 10
    assert values["server"]["startupProbe"]["failureThreshold"] == 180
    assert values["server"]["startupProbe"]["timeoutSeconds"] == 10
    assert values["server"]["resources"]["requests"]["memory"] == "512Mi"
    assert values["server"]["resources"]["limits"]["memory"] == "1Gi"
    assert values["worker"]["livenessProbe"]["timeoutSeconds"] == 10
    assert values["worker"]["readinessProbe"]["timeoutSeconds"] == 10
    assert values["worker"]["startupProbe"]["failureThreshold"] == 180
    assert values["worker"]["startupProbe"]["timeoutSeconds"] == 10
    assert values["worker"]["resources"]["requests"]["memory"] == "256Mi"
    assert values["worker"]["resources"]["limits"]["memory"] == "512Mi"
    assert values["authentik"]["existingSecret"]["secretName"] == "authentik-bootstrap"
    assert (
        values["authentik"]["env"][0]["value"]
        == "authentik-db-pooler-rw-session.databases.svc.cluster.local"
    )


def test_authentik_database_cluster_spreads_pods_across_nodes():
    cluster = yaml.safe_load(AUTHENTIK_DB_CLUSTER.read_text(encoding="utf-8"))

    assert cluster["metadata"]["name"] == "authentik-db"
    assert cluster["spec"]["instances"] == 3
    assert cluster["spec"]["topologySpreadConstraints"] == [
        {
            "maxSkew": 1,
            "topologyKey": "kubernetes.io/hostname",
            "whenUnsatisfiable": "ScheduleAnyway",
            "labelSelector": {
                "matchLabels": {
                    "cnpg.io/cluster": "authentik-db",
                }
            },
        }
    ]
    assert cluster["spec"]["affinity"]["enablePodAntiAffinity"] is True
    assert cluster["spec"]["affinity"]["topologyKey"] == "kubernetes.io/hostname"


def test_authentik_passwordless_blueprint_uses_valid_instantiate_label():
    manifest = yaml.safe_load(AUTHENTIK_PASSWORDLESS_BLUEPRINT.read_text(encoding="utf-8"))

    labels = manifest["metadata"]["labels"]
    assert labels == {"blueprints.goauthentik.io/instantiate": "true"}


def test_authentik_passwordless_blueprint_forces_portal_user_passkey_onboarding():
    text = AUTHENTIK_PASSWORDLESS_BLUEPRINT.read_text(encoding="utf-8")

    assert "name: twinbox-passwordless-onboarding-validation" in text
    assert "not_configured_action: configure" in text
    assert "configuration_stages:" in text
    assert "- !KeyOf twinbox-webauthn-setup" in text
    assert 'pending_user.attributes.get("twinbox.io/passwordless-onboarding") is True' in text
    assert "WebAuthnDevice.objects.filter(user=pending_user, confirmed=True).exists()" in text
    assert "pending_user.set_unusable_password()" in text
    assert 'attributes.pop("twinbox.io/passwordless-onboarding", None)' in text
    assert 'authenticator_attachment: ""' not in text
    assert "last_auth_threshold: 0" not in text
    assert "webauthn_stage: !KeyOf twinbox-passwordless-validation" in text
    assert (
        'stage: !Find [authentik_stages_password.passwordstage, [name, "default-authentication-password"]]'
        in text
    )
    assert "policy_engine_mode: all" in text
    assert "order: 40" in text


def test_dashy_deployment_uses_a_published_image_tag():
    text = (REPO_ROOT / "gitops" / "platform-apps" / "dashy" / "deployment.yaml").read_text(
        encoding="utf-8"
    )
    pvc_text = (REPO_ROOT / "gitops" / "platform-apps" / "dashy" / "pvc.yaml").read_text(
        encoding="utf-8"
    )
    assert "replicas: 1" in text
    assert "strategy:\n    type: Recreate" in text
    assert "kubernetes.io/hostname" not in text
    assert "persistentVolumeClaim:" in text
    assert "claimName: dashy-data" in text
    assert "ReadWriteOnce" in pvc_text
    assert "ReadWriteMany" not in pvc_text
    assert "storage: 5Gi" in pvc_text
    assert "emptyDir: {}" not in text
    assert 'target = Path("/app/user-data/config.yml")' in text
    assert "requests:" in text
    assert "cpu: 500m" in text
    assert "memory: 512Mi" in text
    assert 'cpu: "2"' in text
    assert "memory: 2Gi" in text
    assert "failureThreshold: 120" in text
    assert (
        "ghcr.io/lissy93/dashy@sha256:be489008a0ea4f60030ca3e25e55007425d3dfa8ecf48b5722ad9c4f3a12bff6"
        in text
    )
    assert "ghcr.io/lissy93/dashy:latest" not in text
    assert "ghcr.io/lissy93/dashy:v3.1.1" not in text
    assert "ghcr.io/lissy93/dashy:v3.2.3" not in text


def test_dashy_argo_application_manages_the_platform_overlay():
    text = DASHY_APP.read_text(encoding="utf-8")
    assert "kind: ApplicationSet" in text
    assert "name: dashy-set" in text
    assert "path: gitops/platform-apps/dashy" in text
    assert "name: dashy-wiredoor" not in text
    assert "name: dashy-tailscale" not in text
    assert 'Host(`admin.{{index .metadata.annotations "twinbox.io/public-zone-name"}}`)' in text
    assert '.metadata.labels "twinbox.io/resource-profile"' in text
    assert 'dig "twinbox.io/resource-profile"' not in text
    assert "CreateNamespace=true" in text


def test_dashy_kustomization_includes_a_pvc():
    text = (REPO_ROOT / "gitops" / "platform-apps" / "dashy" / "kustomization.yaml").read_text(
        encoding="utf-8"
    )
    assert "pvc.yaml" in text
    assert "deployment.yaml" in text
    assert "ingressroute.yaml" in text


def test_karakeep_argo_application_manages_the_platform_overlay():
    text = _karakeep_app_text()
    kustomization_text = KARAKEEP_PLATFORM_KUSTOMIZATION.read_text(encoding="utf-8")

    assert "kind: ApplicationSet" in text
    assert "name: karakeep-set" in text
    assert 'twinbox.io/app-karakeep: "enabled"' in text
    assert 'targetRevision: "0.32.0"' in text
    assert (
        'applicationHost: karakeep.{{index .metadata.annotations "twinbox.io/public-zone-name"}}'
        in text
    )
    assert "secrets:" in text
    assert "enabled: false" in text
    assert "path: gitops/platform-apps/karakeep" in text
    assert "CreateNamespace=true" in text
    assert "name: karakeep-wiredoor" not in text
    assert "name: karakeep-tailscale" not in text
    assert "kind: Kustomization" in kustomization_text
    assert "namespace.yaml" in kustomization_text
    assert "externalsecret.yaml" in kustomization_text
    assert "ingressroute.yaml" in kustomization_text
    externalsecret_text = (
        REPO_ROOT / "gitops" / "platform-apps" / "karakeep" / "externalsecret.yaml"
    ).read_text(encoding="utf-8")
    assert "name: karakeep" in externalsecret_text
    assert "NEXTAUTH_SECRET" in externalsecret_text
    assert "OAUTH_CLIENT_ID" in externalsecret_text
    assert "OAUTH_CLIENT_SECRET" in externalsecret_text
    assert "name: karakeep-meilesearch" in externalsecret_text
    assert "MEILI_MASTER_KEY" in externalsecret_text
    assert "twinbox/global/karakeep" in externalsecret_text


def test_pgadmin4_argo_application_manages_the_platform_overlay():
    text = _pgadmin_app_text()
    kustomization_text = (
        REPO_ROOT / "gitops" / "platform-apps" / "pgadmin4" / "kustomization.yaml"
    ).read_text(encoding="utf-8")

    assert "kind: Application" in text
    assert "path: gitops/platform-apps/pgadmin4" in text
    assert "CreateNamespace=true" in text
    assert "name: pgadmin4-wiredoor" not in text
    assert "name: pgadmin4-tailscale" not in text
    assert "Host(`pgadmin4.__ZONE_NAME__`)" in text
    assert "kind: Kustomization" in kustomization_text
    assert "configmap.yaml" in kustomization_text
    assert "deployment.yaml" in kustomization_text


def test_install_dashy_step_refreshes_platform_ingress_before_restart():
    text = (
        REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-dashy-dashboard" / "run.sh"
    ).read_text(encoding="utf-8")
    assert "Applying Dashy Argo CD application" in text
    assert "Waiting for Dashy OIDC secret" in text
    assert "Rendering and applying Dashy start page config" not in text
    assert "gitops/apps/dashy.yaml" in text
    assert "scripts/manager/apply-argocd-application.sh" in text
    assert '--application "dashy"' in text
    assert '--destination-namespace "dashy"' in text
    assert (
        "kubectl -n dashy wait --for=condition=Ready externalsecret/dashy-oidc --timeout=10m"
        in text
    )
    assert "kubectl -n dashy rollout status deployment/dashy --timeout=10m" in text


def test_install_dashy_step_sets_explicit_authentik_signing_key():
    text = (
        REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-dashy-dashboard" / "run.sh"
    ).read_text(encoding="utf-8")
    assert (
        'AUTHENTIK_SIGNING_KEY_NAME="${AUTHENTIK_SIGNING_KEY_NAME:-authentik Self-signed Certificate}"'
        in (REPO_ROOT / "scripts" / "manager" / "authentik-auth.sh").read_text(encoding="utf-8")
    )
    assert "authentik_resolve_signing_key_id" in text
    assert '--arg signing_key "$signing_key_id"' in text
    assert "signing_key: $signing_key" in text
    assert "Could not resolve Authentik signing key ID for ${AUTHENTIK_SIGNING_KEY_NAME}" in text


def test_authentik_helper_resolves_signing_key():
    text = (REPO_ROOT / "scripts" / "manager" / "authentik-auth.sh").read_text(encoding="utf-8")
    assert (
        'AUTHENTIK_SIGNING_KEY_NAME="${AUTHENTIK_SIGNING_KEY_NAME:-authentik Self-signed Certificate}"'
        in text
    )
    assert "authentik_resolve_signing_key_id()" in text
    assert "/crypto/certificatekeypairs/?page_size=200" in text
    assert ".pk // .id // .uuid // empty" in text
    assert "local max_attempts=5" in text
    assert (
        'response="$(authentik_api_get "/flows/instances/?slug=${slug}&page_size=100")" || return 1'
        in text
    )
    assert "authentik_ensure_default_provider_flows()" in text
    assert '"/flows/instances/${slug}/"' not in text
    assert 'response="$(authentik_api_get "/core/groups/?page_size=200")" || return 1' in text


def test_provision_step_rebuilds_completed_clusters_with_a_new_session():
    text = APP_JSX.read_text(encoding="utf-8")

    assert "shouldReuseProvisionClusterSession" in text
    assert '["bootstrapped", "provisioned"]' in text
    assert 'step.id === "provision-nodes"' in text
    assert "body.cluster_instance_id = clusterInstanceIdRef.current" in text
    assert 'if (step.id === "provision-nodes")' in text
    assert "else if (clusterInstanceIdRef.current)" in text
    assert "cluster?.status" in text


def test_authentik_oidc_consumer_scripts_set_explicit_signing_key():
    consumer_paths = [
        REPO_ROOT / "categories" / "talos-cluster" / "steps" / "configure-argocd-oidc" / "run.sh",
        REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-dashy-dashboard" / "run.sh",
        REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-grafana" / "run.sh",
        REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-headlamp" / "run.sh",
        REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-pgadmin4" / "run.sh",
    ]

    for path in consumer_paths:
        text = path.read_text(encoding="utf-8")
        assert 'signing_key_id="$(authentik_resolve_signing_key_id)"' in text
        assert (
            "Could not resolve Authentik signing key ID for ${AUTHENTIK_SIGNING_KEY_NAME}" in text
        )
        assert '--arg signing_key "$signing_key_id"' in text
        assert "signing_key: $signing_key" in text


def test_configure_argocd_oidc_refreshes_platform_ingress_without_waiting():
    text = (
        REPO_ROOT / "categories" / "talos-cluster" / "steps" / "configure-argocd-oidc" / "run.sh"
    ).read_text(encoding="utf-8")

    assert "Refreshing platform-ingress so Argo CD picks up OIDC config" in text
    assert "gitops/apps/platform-ingress.yaml" in text
    assert '--application "platform-ingress"' in text
    assert '--destination-namespace "argocd"' in text
    assert "--no-wait" not in text
    assert "wait_for_argocd_oidc_config" in text
    assert "patch_live_argocd_config" not in text
    assert "platform-ingress did not refresh argocd-cm in time" not in text
    assert 'argocd_cli_file="$secrets_dir/argocd-cli.json"' in text
    assert 'bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \\' in text
    assert '--secret-name "argocd-cli"' in text
    assert '--required-keys "ARGOCD_HOST,CLUSTER_ID"' in text


def test_management_vm_maintenance_installs_wget():
    text = (REPO_ROOT / "ansible" / "management-vm-maintenance.yml").read_text(encoding="utf-8")
    assert "wget" in text
    assert "jq" in text


def test_cloudtty_platform_ingress_is_committed_to_gitops():
    script_text = _cloudtty_script_text()

    assert 'PLATFORM_DIR="$WORKSPACE_ROOT/gitops/platform-apps/cloudtty"' in script_text
    assert 'kubectl apply -f "$PLATFORM_DIR/authentik-forwardauth-middleware.yaml"' in script_text
    assert 'kubectl apply -f "$rendered_ingressroute"' in script_text


def test_termix_browser_ssh_step_bootstraps_role_based_management_vm_access():
    step_manifest_text = _termix_step_manifest_text()
    step_text = _termix_step_text()
    setup_authentik_text = _termix_setup_authentik_text()
    setup_text = _termix_setup_text()
    deployment_text = _termix_deployment_text()
    configmap_text = TERMIX_CONFIGMAP.read_text(encoding="utf-8")
    externalsecret_text = _termix_externalsecret_text()
    app_manifest_text = TERMIX_APP_MANIFEST.read_text(encoding="utf-8")
    namespace_text = TERMIX_NAMESPACE.read_text(encoding="utf-8")
    ingressroute_text = TERMIX_INGRESSROUTE.read_text(encoding="utf-8")

    assert "title: Install Browser SSH" in step_manifest_text
    assert (
        "summary: Provision Termix and the opkssh Authentik application for admin-only browser SSH into the Management VM and bastion."
        in step_manifest_text
    )
    assert "TWINBOX_TALOSCONFIG_FILE:" in step_manifest_text
    assert "item: talosconfig" in step_manifest_text
    assert "script: categories/talos-cluster/steps/install-browser-ssh/run.sh" in step_manifest_text
    assert 'bash "$WORKSPACE_ROOT/scripts/manager/setup-opkssh-authentik.sh"' in step_text
    assert 'bash "$WORKSPACE_ROOT/scripts/manager/setup-termix-authentik.sh"' in step_text
    assert 'bash "$WORKSPACE_ROOT/scripts/manager/setup-termix.sh"' in step_text

    assert "redirect_uris: [" in setup_authentik_text
    assert 'matching_mode: "strict"' in setup_authentik_text
    assert "property_mappings: $property_mappings" in setup_authentik_text
    assert "find_scope_mapping_json_by_name_and_scope()" in setup_authentik_text
    assert "upsert_scope_mapping()" in setup_authentik_text
    assert '"Termix groups"' in setup_authentik_text
    assert '"Expose Termix group membership"' in setup_authentik_text
    assert "groups = [group.name for group in request.user.ak_groups.all()]" in setup_authentik_text
    assert 'if request.user.is_superuser and "admins" not in groups:' in setup_authentik_text
    assert "OIDC_SCOPES" in setup_authentik_text
    assert "OIDC_ADMIN_GROUP" in setup_authentik_text
    assert "OIDC_ALLOWED_USERS" in setup_authentik_text
    assert "OIDC_ALLOW_REGISTRATION" in setup_authentik_text
    assert "OIDC_FORCE_HTTPS" in setup_authentik_text
    assert "SSH_PRIVATE_KEY" in setup_authentik_text
    assert "OAuth2 provider '${provider_name}' already exists" in setup_authentik_text
    assert "Application '${application_slug}' already exists" in setup_authentik_text
    assert ">&2" in setup_authentik_text
    assert (
        'authentik_api_get "/core/applications/${application_slug}/" 2>/dev/null || true'
        in setup_authentik_text
    )
    assert '"/core/applications/?search=$(printf' in setup_authentik_text
    assert '"/core/applications/?slug=$(printf' not in setup_authentik_text
    assert "provider: ($provider_pk | tonumber? // $provider_pk)" in setup_authentik_text
    assert 'mktemp "${TMPDIR:-/tmp}/termix-secret-XXXXXX"' in setup_authentik_text
    assert 'mktemp "${TMPDIR:-/tmp}/termix-secret-XXXXXX.json"' not in setup_authentik_text
    assert '--secret-name "termix"' in setup_authentik_text
    assert (
        '--required-keys "OIDC_CLIENT_ID,OIDC_CLIENT_SECRET,OIDC_ISSUER_URL,OIDC_AUTHORIZATION_URL,OIDC_TOKEN_URL,OIDC_USERINFO_URL,OIDC_SCOPES,OIDC_ADMIN_GROUP,OIDC_ALLOWED_USERS,OIDC_ALLOW_REGISTRATION,OIDC_FORCE_HTTPS,TERMIX_ADMIN_PASSWORD"'
        in setup_authentik_text
    )
    assert '--application "termix"' in setup_authentik_text
    assert '--destination-namespace "termix"' in setup_authentik_text
    assert "--skip-namespace-baseline" in setup_authentik_text
    assert "--no-wait" in setup_authentik_text
    assert "rollout restart deployment/termix" in setup_authentik_text
    assert "ensure-netbird-service.sh" in setup_authentik_text
    assert '--service-name "termix"' in setup_authentik_text
    assert '--service-domain "termix.${public_zone_name}"' in setup_authentik_text
    assert "managedNamespaceMetadata:" in app_manifest_text
    assert "pod-security.kubernetes.io/enforce: privileged" in app_manifest_text
    assert "pod-security.kubernetes.io/audit: privileged" in app_manifest_text
    assert "pod-security.kubernetes.io/warn: privileged" in app_manifest_text
    assert "pod-security.kubernetes.io/enforce: privileged" in namespace_text
    assert "pod-security.kubernetes.io/audit: privileged" in namespace_text
    assert "pod-security.kubernetes.io/warn: privileged" in namespace_text
    assert "authentik-forwardauth" not in ingressroute_text

    assert "TERMIX_ADMIN_PASSWORD" in setup_text
    assert 'TERMIX_URL="${TERMIX_URL:-}"' in setup_text
    assert "setup_termix_forward" in setup_text
    assert 'kubectl -n termix port-forward "svc/termix" "${port}:80"' in setup_text
    assert "${TERMIX_URL}/health" in setup_text
    assert "X-Electron-App: true" in setup_text
    assert "${TERMIX_URL}/users/database-health-check" not in setup_text
    assert "users/setup-required" in setup_text
    assert "setup_required == true" in setup_text
    assert "users/login" in setup_text
    assert "resolve_management_vm_ip" in setup_text
    assert "netbird_bastion_secret" in setup_text
    assert "NETBIRD_PRIVATE_IP" in setup_text
    assert "extract_first_ipv4" in setup_text
    assert "SSH_PRIVATE_KEY is missing" in setup_text
    assert "discover_management_netbird_ip" in setup_text
    assert '"Authorization": f"Token {token}"' in setup_text
    assert "discover_bastion_netbird_ip" in setup_text
    assert "netbird_peer_ip_by_name" in setup_text
    assert ".kube/config" in setup_text
    assert ".talos/config" in setup_text
    assert "Management VM Password" in setup_text
    assert "Bastion VM SSH Key" in setup_text
    assert "Bastion VM" in setup_text
    assert "Management VM NetBird IP" in setup_text
    assert "Bastion NetBird IP" in setup_text
    assert "browser-ssh" in setup_text
    assert "Browser SSH" in setup_text
    assert "/credentials" in setup_text
    assert "/host/db/host" in setup_text
    assert "/ssh/db/host" not in setup_text
    assert "/rbac/roles" in setup_text
    assert "/rbac/users/" in setup_text
    assert "/rbac/host/" in setup_text
    assert 'authType: "credential"' in setup_text
    assert 'authType: "key"' in setup_text
    assert 'authType: "opkssh"' in setup_text
    assert 'authType: "OPKSSH"' not in setup_text
    assert 'keyType: "auto"' in setup_text
    assert "credentialId: ($credential_id | tonumber? // $credential_id)" in setup_text
    assert "share_termix_host_with_browser_role" in setup_text
    assert "ensure_browser_ssh_role_for_admins" in setup_text
    assert ".isAdmin == true" in setup_text
    assert "enableTerminal: true" in setup_text
    assert "showTerminalInSidebar: true" in setup_text
    assert "enableSsh: true" in setup_text

    assert "termix-users-rbac-patch.mjs" in configmap_text
    assert "process.env.OIDC_ADMIN_GROUP" in configmap_text
    assert 'process.env.TERMIX_BROWSER_ROLE_NAME || "browser-ssh"' in configmap_text
    assert "Twinbox Browser SSH role assigned to OIDC admin" in configmap_text
    assert "twinbox_browser_ssh_role_sync" in configmap_text

    assert "OIDC_ALLOWED_USERS" in externalsecret_text
    assert "OIDC_ALLOW_REGISTRATION" in externalsecret_text
    assert "OIDC_FORCE_HTTPS" in externalsecret_text
    assert "OIDC_ADMIN_GROUP" in externalsecret_text
    assert "OIDC_SCOPES" in externalsecret_text
    assert "TERMIX_SSH_PRIVATE_KEY" in externalsecret_text
    assert "twinbox/global/netbird-browser-ssh" in externalsecret_text
    assert "NB_SETUP_KEY" in externalsecret_text
    assert "NB_MANAGEMENT_URL" in externalsecret_text
    assert "NB_HOSTNAME" in externalsecret_text
    assert "name: netbird" in deployment_text
    assert "node /tmp/termix-users-rbac-patch.mjs" in deployment_text
    assert "exec /entrypoint.sh" in deployment_text
    assert "TERMIX_BROWSER_ROLE_NAME" in deployment_text
    assert "subPath: termix-users-rbac-patch.mjs" in deployment_text
    pinned_match = re.search(r"^PINNED_NETBIRD_VERSION=(\S+)$", _pinned_defaults_text(), re.M)
    assert pinned_match
    assert f"image: netbirdio/netbird:{pinned_match.group(1)}" in deployment_text
    assert "NB_SETUP_KEY" in deployment_text
    assert "NB_MANAGEMENT_URL" in deployment_text
    assert "NB_HOSTNAME" in deployment_text
    assert "name: prepare-opkssh-directory" in deployment_text
    assert "image: ghcr.io/lukegus/termix:release-2.3.1" in deployment_text
    assert "mkdir -p /app/data/.opk" in deployment_text
    assert "chmod 0770 /app/data/.opk" in deployment_text
    assert "mountPath: /app/data" in deployment_text
    assert "runAsUser: 0" in deployment_text
    assert "runAsGroup: 0" in deployment_text
    assert "mountPath: /var/lib/netbird" in deployment_text
    assert "subPath: netbird-state" in deployment_text
    assert "path: /dev/net/tun" in deployment_text
    assert "path: /health" in deployment_text
    assert "path: /users/database-health-check" not in deployment_text
    assert "privileged: true" in deployment_text
    assert "runAsUser: 0" in deployment_text
    assert "OIDC_ALLOWED_USERS" not in deployment_text
    assert "OIDC_ALLOW_REGISTRATION" not in deployment_text
    assert "OIDC_FORCE_HTTPS" not in deployment_text


def test_platform_namespace_baseline_covers_shared_overlay_resources():
    assert not (REPO_ROOT / "gitops" / "platform" / "namespaces.yaml").exists()
    assert "namespace.yaml" in (
        REPO_ROOT / "gitops" / "platform-apps" / "pgadmin4" / "kustomization.yaml"
    ).read_text(encoding="utf-8")
    assert "namespace.yaml" in KARAKEEP_PLATFORM_KUSTOMIZATION.read_text(encoding="utf-8")
    assert "db-externalsecret.yaml" in (
        REPO_ROOT / "gitops" / "platform-apps" / "immich" / "kustomization.yaml"
    ).read_text(encoding="utf-8")
    assert "namespace.yaml" not in IMMICH_DB_KUSTOMIZATION.read_text(encoding="utf-8")
    assert "gitops/apps/dashy.yaml" in (
        REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-dashy-dashboard" / "run.sh"
    ).read_text(encoding="utf-8")


def test_gitops_docs_describe_bootstrap_seed_and_current_app_ownership():
    gitops_text = (REPO_ROOT / "gitops" / "README.md").read_text(encoding="utf-8")
    apps_text = (REPO_ROOT / "categories" / "apps" / "README.md").read_text(encoding="utf-8")

    assert "Label-driven ApplicationSets for opt-in apps" in gitops_text
    assert "optional-apps-root.yaml" in gitops_text
    assert "twinbox.io/app-<name>: enabled" in gitops_text
    assert "karakeep" in gitops_text
    assert "gitops/apps/databases.yaml" in gitops_text
    assert "older bootstrap-seeded path" not in gitops_text
    assert (
        "Argo CD creates the live `Application` from `gitops/optional-apps/<app>.yaml`" in apps_text
    )
    assert "GitHub `main` owns the opt-in app definition" in apps_text
    assert "shared `databases` namespace is owned by `gitops/apps/databases.yaml`" in apps_text


def test_platform_ingress_manifest_patches_authentik_callback_routes():
    text = (REPO_ROOT / "gitops" / "apps" / "platform-ingress.yaml").read_text(encoding="utf-8")
    assert "name: traefik-authentik-callback" in text
    assert "name: longhorn-authentik-callback" in text
    assert (
        'Host(`traefik.{{index .metadata.annotations "twinbox.io/public-zone-name"}}`) && PathPrefix(`/outpost.goauthentik.io`)'
        in text
    )
    assert (
        'Host(`longhorn.{{index .metadata.annotations "twinbox.io/public-zone-name"}}`) && PathPrefix(`/outpost.goauthentik.io`)'
        in text
    )


def test_argocd_config_does_not_exclude_managed_endpoints():
    text = ARGOCD_CM.read_text(encoding="utf-8")
    assert "kind: Endpoints" not in text.split("resource.exclusions: |", 1)[1]
    assert "resource.customizations.ignoreResourceUpdates.Endpoints" not in text
    assert "- EndpointSlice" in text


def test_management_console_endpoints_use_placeholders():
    proxmox_text = (
        REPO_ROOT / "gitops" / "platform" / "management-consoles" / "proxmox-endpoints.yaml"
    ).read_text(encoding="utf-8")
    seaweedfs_text = (
        REPO_ROOT / "gitops" / "platform" / "management-consoles" / "seaweedfs-endpoints.yaml"
    ).read_text(encoding="utf-8")
    webwizard_text = (
        REPO_ROOT / "gitops" / "platform" / "management-consoles" / "webwizard-endpoints.yaml"
    ).read_text(encoding="utf-8")
    forgejo_text = (
        REPO_ROOT / "gitops" / "platform" / "management-consoles" / "forgejo-endpoints.yaml"
    ).read_text(encoding="utf-8")
    beszel_text = (
        REPO_ROOT / "gitops" / "platform" / "management-consoles" / "beszel-endpoints.yaml"
    ).read_text(encoding="utf-8")
    endpoint_script_text = (
        REPO_ROOT / "scripts" / "manager" / "ensure-management-endpoints.sh"
    ).read_text(encoding="utf-8")

    assert "ip: __PROXMOX_HOST_IP__" in proxmox_text
    assert "ip: __MGMT_HOST_IP__" in seaweedfs_text
    assert "ip: __MGMT_HOST_IP__" in webwizard_text
    assert "ip: __MGMT_HOST_IP__" in forgejo_text
    assert "ip: __MGMT_HOST_IP__" in beszel_text
    assert "forgejo-endpoints.yaml" in endpoint_script_text
    assert "beszel-endpoints.yaml" in endpoint_script_text


def test_beszel_management_vm_route_uses_native_oidc_without_forwardauth():
    ingress_text = (
        REPO_ROOT / "gitops" / "platform" / "management-consoles" / "beszel-ingressroute.yaml"
    ).read_text(encoding="utf-8")
    service_text = (
        REPO_ROOT / "gitops" / "platform" / "management-consoles" / "beszel-service.yaml"
    ).read_text(encoding="utf-8")
    platform_ingress_text = PLATFORM_INGRESS_APP.read_text(encoding="utf-8")

    assert "Host(`beszel.__ZONE_NAME__`)" in ingress_text
    assert "authentik-forwardauth" not in ingress_text
    assert "port: 8090" in ingress_text
    assert "port: 8090" in service_text
    assert "name: beszel" in platform_ingress_text
    assert (
        'Host(`beszel.{{index .metadata.annotations "twinbox.io/public-zone-name"}}`)'
        in platform_ingress_text
    )


def test_forgejo_management_console_route_uses_native_oidc_and_dashy_tile():
    ingress_text = (
        REPO_ROOT / "gitops" / "platform" / "management-consoles" / "forgejo-ingressroute.yaml"
    ).read_text(encoding="utf-8")
    service_text = (
        REPO_ROOT / "gitops" / "platform" / "management-consoles" / "forgejo-service.yaml"
    ).read_text(encoding="utf-8")
    platform_ingress_text = PLATFORM_INGRESS_APP.read_text(encoding="utf-8")
    platform_kustomization_text = KUSTOMIZATION.read_text(encoding="utf-8")
    step_manifest_text = (
        REPO_ROOT
        / "categories"
        / "talos-cluster"
        / "steps"
        / "install-management-consoles"
        / "step.yaml"
    ).read_text(encoding="utf-8")
    step_script_text = (
        REPO_ROOT
        / "categories"
        / "talos-cluster"
        / "steps"
        / "install-management-consoles"
        / "run.sh"
    ).read_text(encoding="utf-8")
    dashy_config_text = (REPO_ROOT / "lib" / "dashy-config.mjs").read_text(encoding="utf-8")

    assert "Host(`forgejo.__ZONE_NAME__`)" in ingress_text
    assert "authentik-forwardauth" not in ingress_text
    assert "name: forgejo-netbird" in ingress_text
    assert "port: 3001" in ingress_text
    assert "port: 3001" in service_text
    assert "name: forgejo" in platform_ingress_text
    assert (
        'Host(`forgejo.{{index .metadata.annotations "twinbox.io/public-zone-name"}}`)'
        in platform_ingress_text
    )
    assert "management-consoles/forgejo-ingressroute.yaml" in platform_kustomization_text
    assert "management-consoles/forgejo-service.yaml" in platform_kustomization_text
    assert "title: Forgejo" in step_manifest_text
    assert "icon: forgejo" in step_manifest_text
    assert "https://forgejo.__ZONE_NAME__" in step_manifest_text
    assert "kubectl -n longhorn-system get ingressroute/forgejo" in step_script_text
    assert 'key: "forgejo"' not in step_script_text
    assert "forgejo_provider_id" not in step_script_text
    assert "Provisioning native Authentik OIDC login for Forgejo" in step_script_text
    assert "openbao_read_global_secret_json forgejo-oidc" in step_script_text
    assert '--secret-name "forgejo-oidc"' in step_script_text
    assert (
        'forgejo_redirect_uri="${forgejo_host}/user/oauth2/${forgejo_auth_name}/callback"'
        in step_script_text
    )
    assert (
        'forgejo_discovery_url="${forgejo_issuer_url}.well-known/openid-configuration"'
        in step_script_text
    )
    assert 'create_or_update_oauth2_provider "$forgejo_provider_name"' in step_script_text
    assert '"/providers/oauth2/"' in step_script_text
    assert 'issuer_mode: "per_provider"' in step_script_text
    assert "configure_forgejo_oidc_auth_source" in step_script_text
    assert "forgejo admin auth add-oauth" in step_script_text
    assert "forgejo admin auth update-oauth" in step_script_text
    assert "--provider openidConnect" in step_script_text
    assert "docker exec -u git twinbox-forgejo bash -lc" in step_script_text
    assert "docker exec twinbox-forgejo sh -lc" not in step_script_text
    assert '--auto-discover-url "$FORGEJO_OIDC_DISCOVERY_URL"' in step_script_text
    assert '--scopes "openid email profile"' in step_script_text
    assert 'upsert_env_value "$env_file" "FORGEJO_ROOT_URL" "$forgejo_root_url"' in step_script_text
    assert "TWINBOX_HOST_RUNTIME_DIR" in step_script_text
    assert "forgejo_legacy_proxy_provider_id" in step_script_text
    assert "[$traefik, $longhorn, $hubble, $proxmox, $webwizard, $forgejo]" not in step_script_text
    assert '--service-name "forgejo"' in step_script_text
    assert (
        '--service-domain "forgejo.$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")"'
        in step_script_text
    )
    assert '["Forgejo", "forgejo"]' in dashy_config_text
    for icon_path in [
        REPO_ROOT / "manager-web" / "src" / "assets" / "step-icons" / "forgejo.svg",
        REPO_ROOT / "manager-web" / "public" / "assets" / "step-icons" / "forgejo.svg",
        REPO_ROOT / "portal" / "public" / "assets" / "step-icons" / "forgejo.svg",
    ]:
        assert icon_path.exists()


def test_seaweedfs_admin_routes_to_the_admin_web_port():
    text = (
        REPO_ROOT / "gitops" / "platform" / "management-consoles" / "seaweedfs-ingressroute.yaml"
    ).read_text(encoding="utf-8")
    admin_text = (
        REPO_ROOT
        / "gitops"
        / "platform"
        / "management-consoles"
        / "seaweedfs-admin-ingressroute.yaml"
    ).read_text(encoding="utf-8")

    assert "PathPrefix(`/cache`)" in text
    assert "name: seaweedfs-cache-prefix" in text
    assert "prefix: /mastodon" in text
    assert text.count("name: authentik-forwardauth") == 2
    assert text.count("port: 8333") == 2
    assert text.count("port: 8888") == 2
    assert "port: 23646" not in text
    assert "name: seaweedfs" in admin_text
    assert "port: 23646" in admin_text
    assert "port: 8888" not in admin_text


def test_authentik_callback_ingressroutes_reference_the_authentik_namespace():
    hubble_callback_text = (
        REPO_ROOT / "gitops" / "platform" / "hubble" / "authentik-callback-ingressroute.yaml"
    ).read_text(encoding="utf-8")
    longhorn_callback_text = (
        REPO_ROOT
        / "gitops"
        / "platform"
        / "management-consoles"
        / "authentik-callback-ingressroute.yaml"
    ).read_text(encoding="utf-8")
    traefik_callback_text = (
        REPO_ROOT / "gitops" / "platform" / "traefik" / "authentik-callback-ingressroute.yaml"
    ).read_text(encoding="utf-8")

    for callback_text in (
        hubble_callback_text,
        longhorn_callback_text,
        traefik_callback_text,
    ):
        assert "name: authentik-server" in callback_text
        assert "namespace: authentik" in callback_text


def test_hubble_authentik_callback_ingressroute_uses_the_real_host():
    hubble_callback_text = HUBBLE_AUTHENTIK_CALLBACK_INGRESSROUTE.read_text(encoding="utf-8")

    assert "Host(`hubble.bierineenweek.nl`)" in hubble_callback_text
    assert "__ZONE_NAME__" not in hubble_callback_text


def test_bootstrap_scripts_use_the_management_vm_ip_for_seaweedfs():
    start_manager_text = START_MANAGER_SCRIPT.read_text(encoding="utf-8")
    bootstrap_vm_text = BOOTSTRAP_VM_SCRIPT.read_text(encoding="utf-8")
    helper_text = MANAGEMENT_IP_HELPER.read_text(encoding="utf-8")

    assert "management-ip.sh" in start_manager_text
    assert "management-ip.sh" in bootstrap_vm_text
    assert "hostname -I" not in start_manager_text
    assert "hostname -I" not in bootstrap_vm_text
    assert "hostname -I" not in helper_text
    assert "resolve_management_vm_ip()" in helper_text
    assert "python3 - <<'PY'" in helper_text
    assert "ip route get 1.1.1.1" in helper_text
    assert "192.168.1.50:8333" not in start_manager_text
    assert "192.168.1.50:8333" not in bootstrap_vm_text
    assert start_manager_text.index("s3.configure --user") < start_manager_text.index(
        "s3.bucket.create -name"
    )
    assert "SeaweedFS bucket ${SEAWEEDFS_BUCKET} was not created" in start_manager_text
    assert "ensure_seaweedfs_data_dir()" in bootstrap_vm_text
    assert 'install -d -m 0755 "$TARGET_DIR/seaweedfs/data"' in bootstrap_vm_text
    assert 'sudo chown -R "$USER":"$USER" "$TARGET_DIR/seaweedfs/data"' in bootstrap_vm_text


def test_authentik_consumer_scripts_read_from_openbao():
    consumer_paths = [
        REPO_ROOT / "categories" / "talos-cluster" / "steps" / "configure-argocd-oidc" / "run.sh",
        REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-headlamp" / "run.sh",
        REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-dashy-dashboard" / "run.sh",
        REPO_ROOT
        / "categories"
        / "talos-cluster"
        / "steps"
        / "install-management-consoles"
        / "run.sh",
        REPO_ROOT / "categories" / "talos-cluster" / "steps" / "create-users-and-groups" / "run.sh",
        REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-pgadmin4" / "run.sh",
    ]

    # install-authentik-idp seeds the authentik.json file, so it legitimately references it
    idp_path = (
        REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-authentik-idp" / "run.sh"
    )
    idp_text = idp_path.read_text(encoding="utf-8")
    assert "authentik-auth.sh" in idp_text
    assert "authentik_ensure_token" in idp_text or "authentik_load_bootstrap_secret" in idp_text
    assert "authentik_ensure_default_provider_flows" in idp_text
    assert "local attempts=360" in idp_text
    assert "create_flow_if_missing" not in idp_text
    assert "gitops/databases/immich" not in idp_text
    assert "immich-db" not in idp_text
    assert "immich-db-credentials" not in idp_text

    for path in consumer_paths:
        text = path.read_text(encoding="utf-8")
        assert "authentik-auth.sh" in text
        assert "authentik_ensure_token" in text or "authentik_load_bootstrap_secret" in text
        assert "authentik.json" not in text


def test_authentik_consumer_scripts_use_shared_flow_resolver():
    consumer_paths = [
        REPO_ROOT / "categories" / "talos-cluster" / "steps" / "configure-argocd-oidc" / "run.sh",
        REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-dashy-dashboard" / "run.sh",
    ]

    for path in consumer_paths:
        text = path.read_text(encoding="utf-8")
        assert "authentik_resolve_flow_id" in text
        assert 'api_get "/core/flows/?slug=' not in text


def test_authentik_api_provisioning_steps_bypass_tofu_apply():
    api_paths = [
        REPO_ROOT / "categories" / "talos-cluster" / "steps" / "configure-argocd-oidc" / "run.sh",
        REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-dashy-dashboard" / "run.sh",
        REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-headlamp" / "run.sh",
        REPO_ROOT
        / "categories"
        / "talos-cluster"
        / "steps"
        / "install-management-consoles"
        / "run.sh",
        REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-pgadmin4" / "run.sh",
    ]

    for path in api_paths:
        text = path.read_text(encoding="utf-8")
        assert "authentik_setup_forward" in text
        assert "tofu apply -no-color -auto-approve -input=false" not in text


def test_management_consoles_waits_for_authentik_rollout_before_forwarding():
    text = (
        REPO_ROOT
        / "categories"
        / "talos-cluster"
        / "steps"
        / "install-management-consoles"
        / "run.sh"
    ).read_text(encoding="utf-8")

    assert "wait_for_deployment_rollout" in text
    assert 'wait_for_deployment_rollout "authentik-server" "Authentik server"' in text
    assert 'wait_for_deployment_rollout "authentik-worker" "Authentik worker"' in text
    assert "authentik_ensure_token" in text
    assert "authentik_setup_forward" in text
    assert "curl -X POST" not in text
    assert "log_app_start" in text
    assert "log_app_done" in text
    assert "fail_with_context" in text
    assert "extract_authentik_identifier" in text
    assert "authentik_write_or_fail_context" in text
    assert 'provider_pk="$(create_or_update_proxy_provider' not in text
    assert 'application_pk="$(create_or_update_application' not in text
    assert 'POST "/core/applications/"' in text
    assert "Management console status:" in text
    assert "not attached to outpost" in text
    assert 'manager_api_host_runtime_dir="${TWINBOX_HOST_RUNTIME_DIR:-/host/opt/twinbox}"' in text
    assert 'manager_api_sync_env_file="${manager_api_host_runtime_dir}/.env"' in text
    assert '--env-file "$manager_api_sync_env_file"' in text
    assert '"${manager_api_sync_args[@]}"' in text


def test_twinbox_portal_step_does_not_apply_missing_configmap_manifest():
    text = TWINBOX_PORTAL_STEP_SCRIPT.read_text(encoding="utf-8")
    deployment_text = (
        REPO_ROOT / "gitops" / "platform-apps" / "twinbox-portal" / "deployment.yaml"
    ).read_text(encoding="utf-8")
    pvc_text = (REPO_ROOT / "gitops" / "platform-apps" / "twinbox-portal" / "pvc.yaml").read_text(
        encoding="utf-8"
    )

    assert "gitops/platform-apps/twinbox-portal/configmap.yaml" not in text
    assert "refresh-portal-config.mjs" in text
    assert "replicas: 1" in deployment_text
    assert "ReadWriteOnce" in pvc_text
    assert "ReadWriteMany" not in pvc_text


def test_uninstall_authentik_cleanup_sets_forward_before_app_cleanup():
    text = (REPO_ROOT / "scripts" / "manager" / "uninstall-argocd-application.sh").read_text(
        encoding="utf-8"
    )

    app_detection_index = text.index(
        "immich|nextcloud|audiobookshelf|karakeep|outline|openwebui|hedgedoc|paperless|vaultwarden|jitsi|opencloud|zulip|pixelfed|headlamp|twinbox-portal"
    )
    setup_condition_index = text.index('if [[ "$needs_authentik_cleanup" == "true" ]]')
    setup_forward_index = text.index("authentik_setup_forward", setup_condition_index)
    cleanup_index = text.index("cleanup_app_specific_state", setup_forward_index)

    assert app_detection_index < setup_condition_index
    assert setup_forward_index < cleanup_index
    assert 'kubectl delete -k "$database_app_dir"' in text
    assert 'kubectl delete -f "$database_app_dir"' in text


def test_netbird_bastion_provisioning_fetches_dns_credentials():
    text = NETBIRD_BASTION_STEP_SCRIPT.read_text(encoding="utf-8")
    dns_step_text = (
        REPO_ROOT / "categories" / "talos-cluster" / "steps" / "configure-dns" / "step.yaml"
    ).read_text(encoding="utf-8")
    dns_step_run_text = (
        REPO_ROOT / "categories" / "talos-cluster" / "steps" / "configure-dns" / "run.sh"
    ).read_text(encoding="utf-8")
    question_flow_text = (REPO_ROOT / "manager-web" / "src" / "question-flow.js").read_text(
        encoding="utf-8"
    )
    external_dns_values_text = (REPO_ROOT / "gitops" / "values" / "external-dns.yaml").read_text(
        encoding="utf-8"
    )
    netbird_vars_text = NETBIRD_MODULE_VARS.read_text(encoding="utf-8")
    netbird_main_text = NETBIRD_MODULE_MAIN.read_text(encoding="utf-8")
    netbird_cloud_init_text = NETBIRD_CLOUD_INIT.read_text(encoding="utf-8")

    assert "external-dns-credentials" in text
    assert "dns_provider" in text
    assert "dns_api_token" in text
    assert "dns_api_secret" in text
    assert '-var "dns_provider=$dns_provider"' in text
    assert '-var "dns_api_token=$dns_api_token"' in text
    assert '-var "dns_api_secret=$dns_api_secret"' in text
    assert "base64 -d" in text
    for provider in ("cloudflare", "aws", "digitalocean"):
        assert f'"{provider}"' in text or f"'{provider}'" in text
        assert provider in dns_step_text
        assert provider in dns_step_run_text
        assert provider in question_flow_text
        assert provider in netbird_vars_text
    assert "Google Cloud DNS" not in dns_step_text
    assert "Google Cloud DNS" not in question_flow_text
    for removed in ("google", "google-credentials", "GOOGLE_APPLICATION_CREDENTIALS"):
        assert removed not in text
        assert removed not in dns_step_text
        assert removed not in dns_step_run_text
        assert removed not in question_flow_text
        assert removed not in external_dns_values_text
    assert removed not in netbird_vars_text

    assert 'variable "netbird_admin_token_expire_days"' in netbird_vars_text
    assert "default     = 365" in netbird_vars_text
    assert "admin_token_expire_days" in netbird_main_text
    assert "var.netbird_admin_token_expire_days" in netbird_main_text
    bootstrap_text = NETBIRD_BASTION_BOOTSTRAP_TEMPLATE.read_text(encoding="utf-8")
    assert "ADMIN_TOKEN_EXPIRE_DAYS=${admin_token_expire_days}" in netbird_cloud_init_text
    assert '"pat_expire_in": \'"$ADMIN_TOKEN_EXPIRE_DAYS"\'' in bootstrap_text
    assert '"pat_expire_in": ${ADMIN_TOKEN_EXPIRE_DAYS}' not in bootstrap_text
    assert '"pat_expire_in": 7' not in bootstrap_text


def test_netbird_bastion_falls_back_to_cpx22_on_hetzner_capacity_errors():
    step_text = NETBIRD_BASTION_STEP_MANIFEST.read_text(encoding="utf-8")
    run_text = NETBIRD_BASTION_STEP_SCRIPT.read_text(encoding="utf-8")
    docs_text = (REPO_ROOT / "docs" / "netbird.md").read_text(encoding="utf-8")
    step_data = yaml.safe_load(step_text)
    server_type_input = next(
        input_definition
        for input_definition in step_data["inputs"]
        if input_definition["id"] == "hcloud_server_type"
    )

    assert "default: cax11" in step_text
    assert server_type_input["default"] == "cax11"
    assert server_type_input["options"] == [
        {"label": "CAX11 — ARM64, 2 vCPU / 4 GB", "value": "cax11"},
        {"label": "CPX12 — x86/AMD, 1 vCPU / 2 GB (light/test)", "value": "cpx12"},
        {"label": "CPX22 — x86/AMD, 2 vCPU / 4 GB", "value": "cpx22"},
    ]
    assert "resource_unavailable" in run_text
    assert 'if [[ "$server_type" == "cax11" ]]' in run_text
    assert '-var "server_type=$server_type"' in run_text
    assert "Hetzner placement for cax11 is unavailable; retrying once with cpx22" in run_text
    assert "Cleaning up partially created Hetzner resources before retrying with cpx22" in run_text
    assert "Retrying NetBird VPS OpenTofu configuration with cpx22" in run_text
    assert "Choose `cax11` (default" in docs_text
    assert "`cpx12` (x86/AMD, 1 vCPU/2 GB for light/test use)" in docs_text
    assert "Only an unavailable default `cax11` falls back once to `cpx22`" in docs_text
    assert (
        "If Hetzner returns `resource_unavailable` while placing the default `cax11`" in docs_text
    )


def test_saved_unknown_hcloud_server_type_is_preserved_in_the_dropdown():
    input_options_text = (REPO_ROOT / "manager-web" / "src" / "input-options.js").read_text(
        encoding="utf-8"
    )

    assert "saved value" in input_options_text
    assert "return [...options" in input_options_text


def test_netbird_cloud_init_uses_exact_netbird_cert_and_tcp_passthrough():
    text = (
        NETBIRD_CLOUD_INIT.read_text(encoding="utf-8")
        + "\n"
        + NETBIRD_BASTION_BOOTSTRAP_TEMPLATE.read_text(encoding="utf-8")
    )

    assert "DNS_PROVIDER" in text
    assert "DNS_API_TOKEN" in text
    assert "dnschallenge.provider" in text
    assert "dns_api_token" in text
    assert "CLOUDFLARE_DNS_API_TOKEN" in text
    assert "DO_AUTH_TOKEN" in text
    assert "GOOGLE_APPLICATION_CREDENTIALS" not in text
    assert "google" not in text
    assert "HostSNI(`*`) && !HostSNI(`{netbird_domain}`)" in text
    assert "run_netbird_wildcard_lego()" in text
    assert "install_netbird_wildcard_certificate()" in text
    assert "install_netbird_wildcard_renewal_timer()" in text
    assert "goacme/lego:v4.27.0" in text
    assert '--domains "$PUBLIC_ZONE_NAME"' in text
    assert '--domains "*.$PUBLIC_ZONE_NAME"' in text
    assert "renew --days 30" in text
    assert "netbird-wildcard-certificate.timer" in text
    assert "OnCalendar=daily" in text
    assert 'chown 1000:1000 "$cert_dir"' in text
    assert 'chown 1000:1000 "$cert_file.tmp" "$key_file.tmp"' in text
    assert "tls.domains[0].main" in text
    assert '"traefik.http.routers.netbird-dashboard.tls.domains[0].main": netbird_domain' in text
    assert '"traefik.http.routers.netbird-backend.tls.domains[0].main": netbird_domain' in text
    assert '"traefik.http.routers.netbird-grpc.tls.domains[0].main": netbird_domain' in text
    assert "/opt/netbird/traefik-dynamic.yaml:/opt/netbird/traefik-dynamic.yaml:ro" in text
    assert "--providers.file.filename=/opt/netbird/traefik-dynamic.yaml" in text
    assert '"--providers.docker.network=": "--providers.docker.network=netbird_netbird"' in text
    assert "ensure_network_alias" in text
    assert 'ensure_network_alias(traefik, "netbird", netbird_domain)' in text
    assert 'entry.setdefault("aliases", [])' in text
    assert "traefik-dynamic.yaml" in text
    assert 'data.pop("tls", None)' in text
    assert 'data.pop("http", None)' in text
    assert 'pp_v2["proxyProtocol"] = {"version": 2}' in text
    assert 'netbird_no_store_middleware = "netbird-no-store"' in text
    assert "no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0" in text
    assert '"traefik.http.routers.netbird-dashboard.middlewares"' in text
    assert '"traefik.http.routers.netbird-backend.middlewares"' in text
    assert '"traefik.http.routers.netbird-grpc.middlewares"' in text
    assert "append_csv_label_value" in text
    assert "dashboard_tls_domain_labels" in text
    assert "server_tls_domain_labels" in text
    assert "set_labels(dashboard, dashboard_tls_domain_labels)" in text
    assert (
        "set_labels(netbird_server, {**server_tls_domain_labels, **no_store_middleware_labels})"
        in text
    )
    assert "remove_label_keys(traefik, is_removed_http_wildcard_label)" in text
    assert 'key.startswith("traefik.http.middlewares.netbird-no-store.")' in text
    assert "remove_label_keys(proxy, is_removed_http_wildcard_label)" in text
    assert 'wildcard_volume = "/opt/netbird/certs/wildcard:/wildcard-certs:ro"' in text
    assert '"NB_PROXY_WILDCARD_CERT_DIR": "/wildcard-certs"' in text
    assert "HostRegexp" not in text
    assert "tls.domains[0].sans" not in text
    assert "certFile" not in text
    assert "keyFile" not in text
    assert "/certs/live/{zone}.crt" not in text
    assert "insecureSkipVerify" not in text
    assert "cluster-proxy" not in text
    assert "traefik.http.services.cluster-proxy" not in text
    assert "traefik.http.serverstransports.proxy-insecure" not in text
    assert "NB_PROXY_ACME_CERTIFICATES" in text
    assert '"true"' in text


def test_beszel_install_configures_pocketbase_oauth_options():
    beszel_text = BESZEL_STEP_SCRIPT.read_text(encoding="utf-8")

    assert "oauth2: {" in beszel_text
    assert "enabled: true" in beszel_text
    assert "providers: [" in beszel_text
    assert ".oauth2 = $oauth.oauth2" in beszel_text
    assert "allowOAuth2" not in beszel_text
    assert "enabledOAuth2Providers" not in beszel_text
    assert "userInfoUrl: $userinfo_url" in beszel_text
