import os
import subprocess
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
APPLY_CLUSTER_SCRIPT = REPO_ROOT / "scripts" / "manager" / "apply-cluster.sh"
BOOTSTRAP_SCRIPT = REPO_ROOT / "scripts" / "manager" / "bootstrap-talos.sh"
PROVISION_NODES_SCRIPT = REPO_ROOT / "categories" / "talos-cluster" / "steps" / "provision-nodes" / "run.sh"
MODULE_MAIN = REPO_ROOT / "infra" / "opentofu" / "talos-proxmox" / "main.tf"
MODULE_OUTPUTS = REPO_ROOT / "infra" / "opentofu" / "talos-proxmox" / "outputs.tf"
INSTALL_SECRET_SYNC_SCRIPT = REPO_ROOT / "scripts" / "manager" / "install-secret-sync.sh"
ARGO_MANAGER_SCRIPT = REPO_ROOT / "scripts" / "manager" / "install-argocd.sh"
ARGO_STEP_SCRIPT = REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-argocd" / "run.sh"
ENABLE_ARGOCD_APPS_SCRIPT = REPO_ROOT / "scripts" / "manager" / "enable-argocd-apps.sh"
LONGHORN_STEP_SCRIPT = REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-longhorn-storage" / "run.sh"
LONGHORN_STEP_MANIFEST = REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-longhorn-storage" / "step.yaml"
WHOAMI_STEP_MANIFEST = REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-whoami" / "step.yaml"
HEADLAMP_STEP_MANIFEST = REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-headlamp" / "step.yaml"
GRAFANA_STEP_MANIFEST = REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-grafana" / "step.yaml"
WIREDOOR_GATEWAY_STEP_MANIFEST = REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-wiredoor-gateway" / "step.yaml"
ARGO_BOOTSTRAP_SCRIPT = REPO_ROOT / "gitops" / "install.sh"
ARGO_ROOT = REPO_ROOT / "gitops" / "argocd" / "root.yaml"
LONGHORN_APPLICATION = REPO_ROOT / "gitops" / "longhorn" / "application.yaml"
WHOAMI_DEPLOYMENT = REPO_ROOT / "gitops" / "apps" / "whoami" / "deployment.yaml"
HEADLAMP_VALUES = REPO_ROOT / "gitops" / "values" / "headlamp.yaml"
ROUTES_VALUES = REPO_ROOT / "gitops" / "values" / "routes.yaml"
OPTIONAL_ROUTES_CHART = REPO_ROOT / "gitops" / "optional-routes" / "templates" / "ingressroutes.yaml"
WHOAMI_ROUTES_VALUES = REPO_ROOT / "gitops" / "values" / "optional-routes" / "whoami.yaml"
HEADLAMP_ROUTES_VALUES = REPO_ROOT / "gitops" / "values" / "optional-routes" / "headlamp.yaml"
GRAFANA_ROUTES_VALUES = REPO_ROOT / "gitops" / "values" / "optional-routes" / "grafana.yaml"
WIREDOOR_GATEWAY_ROUTES_VALUES = REPO_ROOT / "gitops" / "values" / "optional-routes" / "wiredoor-gateway.yaml"
TRAEFIK_VALUES = REPO_ROOT / "gitops" / "values" / "traefik.yaml"
WIREDOOR_GATEWAY_VALUES = REPO_ROOT / "gitops" / "values" / "wiredoor-gateway.yaml"
GRAFANA_VALUES = REPO_ROOT / "gitops" / "values" / "grafana.yaml"
TRAEFIK_APP = REPO_ROOT / "gitops" / "argocd" / "apps" / "traefik.yaml"
ROUTES_APP = REPO_ROOT / "gitops" / "argocd" / "apps" / "routes.yaml"
WHOAMI_APP = REPO_ROOT / "gitops" / "argocd" / "optional" / "apps" / "whoami.yaml"
WHOAMI_ROUTES_APP = REPO_ROOT / "gitops" / "argocd" / "optional" / "routes" / "whoami.yaml"
HEADLAMP_APP = REPO_ROOT / "gitops" / "argocd" / "optional" / "apps" / "headlamp.yaml"
HEADLAMP_ROUTES_APP = REPO_ROOT / "gitops" / "argocd" / "optional" / "routes" / "headlamp.yaml"
WIREDOOR_GATEWAY_APP = REPO_ROOT / "gitops" / "argocd" / "optional" / "apps" / "wiredoor-gateway.yaml"
WIREDOOR_GATEWAY_SECRET_APP = REPO_ROOT / "gitops" / "argocd" / "optional" / "apps" / "wiredoor-gateway-secret.yaml"
WIREDOOR_GATEWAY_ROUTES_APP = REPO_ROOT / "gitops" / "argocd" / "optional" / "routes" / "wiredoor-gateway.yaml"
TRAEFIK_DASHBOARD_SECRETSTORE = REPO_ROOT / "gitops" / "routes" / "templates" / "traefik-dashboard-secretstore.yaml"
TRAEFIK_DASHBOARD_EXTERNALSECRET = REPO_ROOT / "gitops" / "routes" / "templates" / "traefik-dashboard-externalsecret.yaml"
WIREDOOR_GATEWAY_SECRETSTORE = REPO_ROOT / "gitops" / "apps" / "wiredoor-gateway-secret" / "secretstore.yaml"
WIREDOOR_GATEWAY_EXTERNALSECRET = REPO_ROOT / "gitops" / "apps" / "wiredoor-gateway-secret" / "externalsecret.yaml"
GRAFANA_SECRET_APP = REPO_ROOT / "gitops" / "argocd" / "optional" / "apps" / "grafana-secret.yaml"
GRAFANA_SECRETSTORE = REPO_ROOT / "gitops" / "apps" / "grafana-secret" / "secretstore.yaml"
GRAFANA_EXTERNALSECRET = REPO_ROOT / "gitops" / "apps" / "grafana-secret" / "externalsecret.yaml"


def _apply_cluster_text() -> str:
    return APPLY_CLUSTER_SCRIPT.read_text(encoding="utf-8")


def _bootstrap_text() -> str:
    return BOOTSTRAP_SCRIPT.read_text(encoding="utf-8")


def _module_text() -> str:
    return MODULE_MAIN.read_text(encoding="utf-8")


def _module_outputs_text() -> str:
    return MODULE_OUTPUTS.read_text(encoding="utf-8")


def _module_variables_text() -> str:
    return (REPO_ROOT / "infra" / "opentofu" / "talos-proxmox" / "variables.tf").read_text(encoding="utf-8")


def _install_secret_sync_text() -> str:
    return INSTALL_SECRET_SYNC_SCRIPT.read_text(encoding="utf-8")


def _argo_manager_text() -> str:
    return ARGO_MANAGER_SCRIPT.read_text(encoding="utf-8")


def _argo_step_text() -> str:
    return ARGO_STEP_SCRIPT.read_text(encoding="utf-8")


def _enable_argocd_apps_text() -> str:
    return ENABLE_ARGOCD_APPS_SCRIPT.read_text(encoding="utf-8")


def _longhorn_step_text() -> str:
    return LONGHORN_STEP_SCRIPT.read_text(encoding="utf-8")


def _longhorn_step_manifest_text() -> str:
    return LONGHORN_STEP_MANIFEST.read_text(encoding="utf-8")


def _argo_bootstrap_text() -> str:
    return ARGO_BOOTSTRAP_SCRIPT.read_text(encoding="utf-8")


def _argo_root_text() -> str:
    return ARGO_ROOT.read_text(encoding="utf-8")


def _longhorn_application_text() -> str:
    return LONGHORN_APPLICATION.read_text(encoding="utf-8")


def _longhorn_values_text() -> str:
    return (REPO_ROOT / "gitops" / "longhorn" / "application.yaml").read_text(encoding="utf-8")


def _whoami_deployment_text() -> str:
    return WHOAMI_DEPLOYMENT.read_text(encoding="utf-8")


def _headlamp_values_text() -> str:
    return HEADLAMP_VALUES.read_text(encoding="utf-8")


def _routes_values_text() -> str:
    return ROUTES_VALUES.read_text(encoding="utf-8")


def _optional_routes_chart_text() -> str:
    return OPTIONAL_ROUTES_CHART.read_text(encoding="utf-8")


def _whoami_routes_values_text() -> str:
    return WHOAMI_ROUTES_VALUES.read_text(encoding="utf-8")


def _headlamp_routes_values_text() -> str:
    return HEADLAMP_ROUTES_VALUES.read_text(encoding="utf-8")


def _grafana_routes_values_text() -> str:
    return GRAFANA_ROUTES_VALUES.read_text(encoding="utf-8")


def _wiredoor_gateway_routes_values_text() -> str:
    return WIREDOOR_GATEWAY_ROUTES_VALUES.read_text(encoding="utf-8")


def _traefik_values_text() -> str:
    return TRAEFIK_VALUES.read_text(encoding="utf-8")


def _wiredoor_gateway_values_text() -> str:
    return WIREDOOR_GATEWAY_VALUES.read_text(encoding="utf-8")


def _traefik_dashboard_secretstore_text() -> str:
    return TRAEFIK_DASHBOARD_SECRETSTORE.read_text(encoding="utf-8")


def _traefik_dashboard_externalsecret_text() -> str:
    return TRAEFIK_DASHBOARD_EXTERNALSECRET.read_text(encoding="utf-8")


def _wiredoor_gateway_secretstore_text() -> str:
    return WIREDOOR_GATEWAY_SECRETSTORE.read_text(encoding="utf-8")


def _wiredoor_gateway_externalsecret_text() -> str:
    return WIREDOOR_GATEWAY_EXTERNALSECRET.read_text(encoding="utf-8")


def _grafana_values_text() -> str:
    return GRAFANA_VALUES.read_text(encoding="utf-8")


def _traefik_app_text() -> str:
    return TRAEFIK_APP.read_text(encoding="utf-8")


def _routes_app_text() -> str:
    return ROUTES_APP.read_text(encoding="utf-8")


def _wiredoor_gateway_app_text() -> str:
    return WIREDOOR_GATEWAY_APP.read_text(encoding="utf-8")


def _wiredoor_gateway_secret_app_text() -> str:
    return WIREDOOR_GATEWAY_SECRET_APP.read_text(encoding="utf-8")


def _grafana_secret_app_text() -> str:
    return GRAFANA_SECRET_APP.read_text(encoding="utf-8")


def _grafana_app_text() -> str:
    return (REPO_ROOT / "gitops" / "argocd" / "optional" / "apps" / "grafana.yaml").read_text(encoding="utf-8")


def _grafana_secretstore_text() -> str:
    return GRAFANA_SECRETSTORE.read_text(encoding="utf-8")


def _grafana_externalsecret_text() -> str:
    return GRAFANA_EXTERNALSECRET.read_text(encoding="utf-8")


def test_apply_cluster_requires_proxmox_env():
    with tempfile.TemporaryDirectory() as td:
        cmd = [
            "bash",
            str(APPLY_CLUSTER_SCRIPT),
            "--cluster-id", "c1",
            "--name", "demo",
            "--controlplane-count", "1",
            "--worker-count", "1",
            "--cpu-cores", "2",
            "--memory-mb", "4096",
            "--disk-gb", "20",
            "--bridge", "vmbr0",
            "--start-vmid", "200",
            "--start-ip", "192.168.1.51",
            "--vip-ip", "192.168.1.50",
            "--node-prefix-length", "24",
            "--gateway-ip", "192.168.1.1",
            "--dns-servers", "1.1.1.1,1.0.0.1",
            "--dns-domain", "cluster.internal",
            "--proxmox-node", "pve",
            "--storage-pool", "local-lvm",
            "--file-datastore", "local",
            "--data-dir", td,
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
            "--cluster-id", "missing",
            "--data-dir", td,
        ]
        proc = subprocess.run(cmd, env=os.environ.copy(), capture_output=True, text=True)
        assert proc.returncode != 0
        assert "cluster not found" in (proc.stdout + proc.stderr)


def test_apply_cluster_uses_pinned_defaults_and_tofu():
    text = _apply_cluster_text()
    assert 'source "$WORKSPACE_ROOT/config/pinned-defaults.sh"' in text
    assert '--vm-node-map) shift 2 ;;' in text
    assert 'command -v "$TOFU_BIN"' in text
    assert '"$TOFU_BIN" -chdir="$work_module_dir" init -input=false' in text
    assert 'TOFU_PARALLELISM="${TOFU_PARALLELISM:-1}"' in text
    assert '"$TOFU_BIN" -chdir="$work_module_dir" apply -input=false -auto-approve -no-color -parallelism="$TOFU_PARALLELISM" -var-file="$tfvars_file"' in text
    assert 'reboot_talos_node() {' in text
    assert 'talosctl reboot \\' in text
    assert 'Rebooting Talos nodes after disk-first switch' in text
    assert 'command -v talosctl' in text
    assert 'export TF_IN_AUTOMATION=1' in text
    assert 'export NO_COLOR=1' in text
    assert 'command -v curl' in text
    assert 'resolve_talos_image_assets()' in text
    assert 'scripts/get-talos-image-factory.sh' in text
    assert 'PINNED_TALOS_IMAGE_SCHEMATIC' not in text
    assert '--preset "${TALOS_IMAGE_PRESET:-qemu-guest-agent}"' not in text
    assert 'TALOS_IMAGE_PRESET' in text
    assert 'talosctl apply-config \\' in text
    assert '--endpoints "$ip" \\' in text
    assert 'Secure Talos apply failed for ${ip}; retrying with --insecure' in text
    assert 'AlreadyExists desc = etcd data directory is not empty' in text
    assert 'talosctl bootstrap' in text
    assert 'bootstrap_mode = "dhcp-first"' in text
    assert '"/image/default/"' not in text
    assert '!= "default"' not in text
    assert 'TALOS_IMAGE_FACTORY_URL:-' not in text
    assert 'TALOS_IMAGE_INSTALLER=' in text
    assert 'TALOS_IMAGE_DOWNLOAD_URL=' in text
    assert 'download_talos_image()' in text
    assert 'talos_image_local_path="$image_cache_dir/talos-${image_cache_key}.iso"' in text
    assert 'controlplane_ipv4_addresses.value' in text
    assert 'worker_ipv4_addresses.value' in text
    assert 'flatten_ipv4_candidates' in text or 'flatten | .[]' in text
    assert 'select(startswith("10.244.") | not)' in text
    assert 'TF_VAR_proxmox_endpoint' in text
    assert 'TF_VAR_proxmox_username' in text
    assert 'TF_VAR_proxmox_password' in text
    assert '--arg proxmox_password "$PROXMOX_PASSWORD"' not in text
    assert 'proxmox_password: $proxmox_password' not in text
    assert 'normalize_json_object()' in text
    assert 'cluster_file="$clusters_dir/${CLUSTER_ID}.json"' in text
    assert 'persisted_vm_node_map="$(jq -c \'.vm_node_map // {}\' "$cluster_file")"' in text
    assert 'vm_node_map_json="$(normalize_json_object "${VM_NODE_MAP:-{}}")"' in text
    assert 'if [[ "$(jq -r \'length\' <<<"$vm_node_map_json")" -eq 0 ]] && [[ -f "$cluster_file" ]]; then' in text
    assert 'Loaded vm_node_map from persisted cluster file ${cluster_file}' in text
    assert 'Unable to resolve vm_node_map for cluster ${CLUSTER_ID}; persist it in ${cluster_file} or pass --vm-node-map' in text
    assert 'validate_vm_node_map' in text
    assert 'log "Talos placement ${name} -> ${host}"' in text
    assert '--argjson vm_node_map "$vm_node_map_json"' in text
    assert 'Talos host placement map written to tfvars' in text
    assert 'vm_node_map: $vm_node_map' in text
    assert 'json_array_from_csv()' in text
    assert 'json_array_from_csv "${DNS_SERVERS:-1.1.1.1,1.0.0.1}"' in text
    assert '--argjson prefix "${NODE_PREFIX_LENGTH:-24}"' in text


def test_longhorn_step_installs_pinned_chart_and_waits_for_health():
    step_text = _longhorn_step_text()
    step_manifest_text = _longhorn_step_manifest_text()
    manifest_text = _longhorn_application_text()
    values_text = _longhorn_values_text()

    assert 'title: Install Longhorn Storage' in step_manifest_text
    assert 'summary: Install Longhorn storage with a pinned Helm chart version and wait for the app to become healthy.' in step_manifest_text
    assert 'runner:' in step_manifest_text
    assert 'KUBECONFIG_FILE:' in step_manifest_text
    assert 'item: kubeconfig' in step_manifest_text
    assert 'script: categories/talos-cluster/steps/install-longhorn-storage/run.sh' in step_manifest_text
    assert 'export KUBECONFIG="$KUBECONFIG_FILE"' in step_text
    assert 'Ensuring longhorn-system namespace exists with privileged Pod Security labels' in step_text
    assert 'kubectl create namespace longhorn-system --dry-run=client -o yaml | kubectl apply --validate=false -f - >/dev/null' in step_text
    assert 'pod-security.kubernetes.io/enforce=privileged' in step_text
    assert 'pod-security.kubernetes.io/enforce-version=latest' in step_text
    assert 'pod-security.kubernetes.io/audit=privileged' in step_text
    assert 'pod-security.kubernetes.io/audit-version=latest' in step_text
    assert 'pod-security.kubernetes.io/warn=privileged' in step_text
    assert 'pod-security.kubernetes.io/warn-version=latest' in step_text
    assert 'kubectl apply --server-side --force-conflicts --validate=false -f "$application_manifest"' in step_text
    assert 'wait_for_application_ready "$application_name"' in step_text
    assert 'application_name="longhorn"' in step_text
    assert 'chart_version="1.11.1"' in step_text
    assert 'source:' in manifest_text
    assert 'repoURL: https://charts.longhorn.io' in manifest_text
    assert 'chart: longhorn' in manifest_text
    assert 'targetRevision: "1.11.1"' in manifest_text
    assert 'helm:' in manifest_text
    assert 'preUpgradeChecker:' in manifest_text
    assert 'defaultSetting:' in manifest_text
    assert 'taintToleration:' in manifest_text
    assert 'jobEnabled: false' in manifest_text
    assert 'longhorn-system' in manifest_text


def test_apply_cluster_renders_dhcp_first_talos_flow_and_tracks_iac_paths():
    text = _apply_cluster_text()
    assert 'helper_output="$("$WORKSPACE_ROOT/scripts/get-talos-image-factory.sh"' in text
    assert '--preset "$talos_image_preset"' in text
    assert '--output shell' in text
    assert 'while IFS= read -r line; do' in text
    assert 'TALOS_IMAGE_INSTALLER=' in text
    assert 'TALOS_IMAGE_DOWNLOAD_URL=' in text
    assert 'cp -R "$MODULE_SOURCE/." "$work_module_dir/"' in text
    assert 'image_cache_key="${image_platform}-${image_arch}-${image_schematic}-${PINNED_TALOS_VERSION}"' in text
    assert 'Downloading Talos ISO' in text
    assert '--arg talos_image_local_path "$talos_image_local_path"' in text
    assert 'nodes: $nodes' in text
    assert 'planned_controlplane_ips' in text
    assert 'discovered_controlplane_ips' in text
    assert 'generate_talos_configs()' in text
    assert 'discover_node_ip()' in text
    assert 'Guest agent reported ${label} at ${candidate}' in text
    assert 'jq -Rn --arg csv "$csv"' in text
    assert 'split(",")' in text
    assert 'map(gsub("^\\\\s+|\\\\s+$"; ""))' in text
    assert 'map(select(length > 0))' in text
    assert 'normalize_json_object()' in text
    assert 'vm_node_map_json="$(normalize_json_object "${VM_NODE_MAP:-{}}")"' in text
    assert '--argjson vm_node_map "$vm_node_map_json"' in text
    assert 'wait_for_talos_api()' in text
    assert 'bootstrap_cluster()' in text
    assert 'sync_user_kubeconfig()' in text
    assert 'sync_user_talosconfig()' in text
    assert 'talosctl config node "$default_node_ip"' in text
    assert 'talosctl config endpoint "$default_node_ip"' in text
    assert 'Reusing existing OpenTofu workspace at ${work_module_dir}' in text
    assert 'echo "    image: ${image_installer}"' in text
    assert 'image_installer="${line#TALOS_IMAGE_INSTALLER=}"' in text
    assert 'image_extensions=' not in text
    assert 'TALOS_IMAGE_EXTENSIONS=' not in text


def test_provision_nodes_step_returns_refs_not_kubeconfig_paths():
    text = PROVISION_NODES_SCRIPT.read_text(encoding="utf-8")
    assert 'secret_refs: .metadata.secret_refs' in text
    assert 'kubeconfig_path' not in text
    assert 'Using ${effective_vm_node_map_source} vm_node_map:' in text
    assert '--vm-node-map "$effective_vm_node_map"' in text


def test_manager_worker_image_includes_talos_image_factory_helper():
    text = (REPO_ROOT / "manager-worker" / "Dockerfile").read_text(encoding="utf-8")
    assert 'ARG TALOSCTL_VERSION=v1.12.6' in text
    assert 'ARG BW_VERSION=v1.22.1' in text
    assert 'COPY lib ./lib' in text
    assert 'install -m 0755 /tmp/bw/bw /usr/local/bin/bw' in text
    assert 'COPY scripts/get-talos-image-factory.sh ./scripts/get-talos-image-factory.sh' in text
    assert 'RUN chmod +x ./scripts/get-talos-image-factory.sh' in text


def test_apply_cluster_uses_deterministic_mac_addresses_and_node_inventory():
    text = _apply_cluster_text()
    assert 'deterministic_mac()' in text
    assert "printf '52:54:%02x:%02x:%02x:%02x\\n'" in text
    assert 'type: $type' in text
    assert 'mac: $mac' in text
    assert '--file-datastore) FILE_DATASTORE="$2"; shift 2 ;;' in text
    assert 'file_datastore: $file_datastore' in text


def test_bootstrap_talos_uses_discovered_ips_and_records_runtime_state():
    text = _bootstrap_text()
    assert '(.discovered_controlplane_ips // .controlplane_ips // [])[]' in text
    assert '(.discovered_worker_ips // .worker_ips // [])[]' in text
    assert 'talosctl bootstrap' in text
    assert 'talosctl kubeconfig' in text
    assert 'qm guest cmd' not in text
    assert 'detach_all_vm_isos' not in text


def test_install_secret_sync_installs_eso_and_applies_secret_sync_manifests():
    text = _install_secret_sync_text()
    assert 'source "$WORKSPACE_ROOT/config/pinned-defaults.sh"' in text
    assert 'PINNED_EXTERNAL_SECRETS_CHART_VERSION' in text
    assert 'helm repo add external-secrets https://charts.external-secrets.io' in text
    assert 'helm upgrade --install external-secrets external-secrets/external-secrets' in text
    assert '--set-json "tolerations=${control_plane_tolerations}"' in text
    assert '--set-json "webhook.tolerations=${control_plane_tolerations}"' in text
    assert '--set-json "certController.tolerations=${control_plane_tolerations}"' in text
    assert 'node-role.kubernetes.io/control-plane' in text
    assert 'node-role.kubernetes.io/master' in text
    assert 'kubectl rollout status deployment/external-secrets' in text
    assert 'kind: SecretStore' in text
    assert 'kind: ExternalSecret' in text
    assert 'kind: NetworkPolicy' in text
    assert 'bw login --apikey >/dev/null' in text
    assert 'export BW_SESSION="\\$(bw unlock --passwordenv BW_PASSWORD --raw)"' in text
    assert 'bw sync --session "\\${BW_SESSION}" >/dev/null' in text
    assert 'kubectl rollout status deployment/external-secrets-webhook -n "$OPERATOR_NAMESPACE" --timeout=180s' in text
    assert 'kubectl rollout status deployment/external-secrets-cert-controller -n "$OPERATOR_NAMESPACE" --timeout=180s' in text
    assert '--from-literal=BW_SESSION="$cli_session"' not in text
    assert 'Authorization: "Bearer {{ .auth.session }}"' not in text
    assert 'external-secrets.io/type: webhook' not in text
    assert 'bitwarden-webhook-auth' not in text
    assert 'key: BW_SESSION' not in text
    assert 'bitwarden-cli-allow-external-secrets' in text
    assert 'kubernetes.io/metadata.name: ${OPERATOR_NAMESPACE}' in text
    assert 'automountServiceAccountToken: false' in text
    assert 'tolerations:' in text
    assert 'node-role.kubernetes.io/control-plane' in text
    assert 'node-role.kubernetes.io/master' in text
    assert 'securityContext:' in text
    assert 'runAsNonRoot: true' in text
    assert 'runAsUser: 1000' in text
    assert 'runAsGroup: 1000' in text
    assert 'fsGroup: 1000' in text
    assert 'seccompProfile:' in text
    assert 'type: RuntimeDefault' in text
    assert 'allowPrivilegeEscalation: false' in text
    assert 'capabilities:' in text
    assert 'drop:' in text
    assert '- ALL' in text
    assert 'BITWARDENCLI_APPDATA_DIR' in text
    assert 'HOME' in text
    assert '/tmp/bitwarden-cli' in text
    assert 'emptyDir: {}' in text
    assert 'bw serve --hostname 0.0.0.0' in text
    assert 'bw_status="$(bw status | jq -r \'.status // "unauthenticated"\')"' in text
    assert 'if [[ "$bw_status" == "unauthenticated" ]]; then' in text
    assert 'bw sync --session "$session" >/dev/null' in text
    assert 'mktemp -d' not in text
    assert 'livenessProbe:' in text
    assert 'tcpSocket:' in text
    assert 'port: 8087' in text
    assert 'wget' not in text
    assert 'KUBECONFIG_FILE is required' in text


def test_argo_manager_script_requires_kubeconfig_and_calls_gitops_bootstrap():
    text = _argo_manager_text()
    assert 'Usage: $0 [--kube-api-server URL]' in text
    assert 'KUBE_API_SERVER=""' in text
    assert '--kube-api-server' in text
    assert 'Rewriting kubeconfig cluster' in text
    assert 'kubectl config set-cluster "$kube_cluster_name" --kubeconfig "$KUBECONFIG_FILE" --server "$KUBE_API_SERVER" >/dev/null' in text
    assert 'Bootstrapping Argo CD' in text
    assert 'bash "$WORKSPACE_ROOT/gitops/install.sh"' in text
    assert 'KUBECONFIG_FILE is required' in text


def test_argo_step_script_uses_workspace_root_for_manager_bootstrap():
    text = _argo_step_text()
    assert 'WORKSPACE_ROOT="${WORKSPACE_ROOT:-' in text
    assert 'discovered_controlplane_ips[0]' in text
    assert 'bash "$WORKSPACE_ROOT/scripts/manager/install-argocd.sh" --kube-api-server "https://${controlplane_ip}:6443"' in text
    assert 'root_application: $root_application' in text
    assert 'root_applications: $root_applications' in text


def test_argo_bootstrap_script_installs_argocd_and_applies_full_root_application():
    text = _argo_bootstrap_text()
    wait_section = text.split('local resources=(')[1].split('for resource in "${resources[@]}"; do')[0]
    assert 'Creating argocd namespace' in text
    assert 'Installing Argo CD' in text
    assert 'kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply --validate=false -f -' in text
    assert 'kubectl apply --server-side --force-conflicts --validate=false -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.4/manifests/install.yaml' in text
    assert 'control_plane_tolerations' in text
    assert 'Patching statefulset/argocd-application-controller for control-plane tolerations' in text
    assert 'kubectl -n argocd patch' in text
    assert 'patch_argocd_workload_probes()' in text
    assert 'Patching ${resource} liveness probe for single-node bootstrap' in text
    assert '--type strategic -p' in text
    assert '"initialDelaySeconds":300' in text
    assert 'patch_argocd_repo_server_copyutil()' in text
    assert 'Patching deployment/argocd-repo-server copyutil init container for idempotent startup' in text
    assert '/bin/ln -sfn /var/run/argocd/argocd /var/run/argocd/argocd-cmp-server' in text
    assert 'wait_for_available()' in text
    assert 'Waiting for ${resource} to become available' in text
    assert 'kubectl -n argocd wait --for=condition=Available "$resource" --timeout=900s' in text
    assert 'wait_for_statefulset_rollout()' in text
    assert 'kubectl -n argocd rollout status "$resource" --timeout=900s' in text
    assert 'wait_for_statefulset_rollout "statefulset/argocd-application-controller"' in text
    assert 'statefulset/argocd-application-controller' not in wait_section
    assert 'root_applications=(' in text
    assert '"traefik"' in text
    assert '"routes"' in text
    assert '"whoami"' not in text
    assert '"wiredoor-gateway"' not in text
    assert 'wait_for_application_ready()' in text
    assert 'wait_for_root_applications()' in text
    assert 'Waiting for core root applications to become Synced and Healthy' in text
    assert 'kubectl -n argocd get application "$application" -o json' in text
    assert '.status.sync.status // "Unknown"' in text
    assert '.status.health.status // "Unknown"' in text
    assert 'Application/${application} is Synced and Healthy' in text
    assert 'deployment/argocd-applicationset-controller' in text
    assert 'deployment/argocd-repo-server' in text
    assert 'statefulset/argocd-application-controller' in text
    assert 'Applying core Argo root application' in text
    assert 'kubectl apply --validate=false -f "$WORKSPACE_ROOT/gitops/argocd/root.yaml"' in text


def test_enable_argocd_apps_script_maps_optional_apps_and_waits_for_health():
    text = _enable_argocd_apps_text()

    assert 'Usage: $0 --cluster-id ID --enabled-apps CSV --applications CSV' in text
    assert 'Applying optional Argo application ${application}' in text
    assert 'Waiting for application/${application}: sync=${sync_status}, health=${health_status}, phase=${operation_phase}' in text
    assert 'whoami-routes' in text
    assert 'headlamp-routes' in text
    assert 'grafana-secret' in text
    assert 'grafana-routes' in text
    assert 'wiredoor-gateway-secret' in text
    assert 'wiredoor-gateway-routes' in text
    assert 'enabled_optional_apps' in text
    assert 'reduce $enabled_apps[] as $app' in text


def test_bootstrap_apps_tolerate_single_node_control_plane():
    whoami_text = _whoami_deployment_text()
    headlamp_text = _headlamp_values_text()

    assert 'tolerations:' in whoami_text
    assert 'node-role.kubernetes.io/control-plane' in whoami_text
    assert 'node-role.kubernetes.io/master' in whoami_text
    assert 'tolerations:' in headlamp_text
    assert 'node-role.kubernetes.io/control-plane' in headlamp_text
    assert 'node-role.kubernetes.io/master' in headlamp_text


def test_argo_full_root_includes_full_tree():
    text = _argo_root_text()

    assert 'kind: Application' in text
    assert 'name: root' in text
    assert 'path: gitops/argocd/apps' in text
    assert 'syncPolicy:' in text


def test_install_argocd_step_waits_for_root_app_tree():
    text = (REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-argocd" / "step.yaml").read_text(encoding="utf-8")

    assert 'summary: Install Argo CD and wait for the core root application tree to become healthy.' in text
    assert 'report Synced and Healthy' in text
    assert 'traefik and routes' in text
    assert 'Optional applications such as Whoami, Headlamp, Grafana, and Wiredoor are enabled later as separate wizard steps.' in text


def test_optional_step_manifests_chain_the_enabled_apps_flow():
    whoami_text = WHOAMI_STEP_MANIFEST.read_text(encoding="utf-8")
    headlamp_text = HEADLAMP_STEP_MANIFEST.read_text(encoding="utf-8")
    grafana_text = GRAFANA_STEP_MANIFEST.read_text(encoding="utf-8")
    wiredoor_text = WIREDOOR_GATEWAY_STEP_MANIFEST.read_text(encoding="utf-8")

    assert 'order: 31' in whoami_text
    assert 'install-argocd' in whoami_text
    assert 'script: categories/talos-cluster/steps/install-whoami/run.sh' in whoami_text

    assert 'order: 32' in headlamp_text
    assert 'install-whoami' in headlamp_text
    assert 'script: categories/talos-cluster/steps/install-headlamp/run.sh' in headlamp_text

    assert 'order: 33' in grafana_text
    assert 'install-headlamp' in grafana_text
    assert 'script: categories/talos-cluster/steps/install-grafana/run.sh' in grafana_text

    assert 'order: 34' in wiredoor_text
    assert 'install-grafana' in wiredoor_text
    assert 'script: categories/talos-cluster/steps/install-wiredoor-gateway/run.sh' in wiredoor_text


def test_routes_and_wiredoor_secrets_are_vaultwarden_backed():
    traefik_app_text = _traefik_app_text()
    routes_app_text = _routes_app_text()
    whoami_app_text = WHOAMI_APP.read_text(encoding="utf-8")
    whoami_routes_app_text = WHOAMI_ROUTES_APP.read_text(encoding="utf-8")
    headlamp_app_text = HEADLAMP_APP.read_text(encoding="utf-8")
    headlamp_routes_app_text = HEADLAMP_ROUTES_APP.read_text(encoding="utf-8")
    wiredoor_gateway_app_text = _wiredoor_gateway_app_text()
    wiredoor_gateway_secret_app_text = _wiredoor_gateway_secret_app_text()
    routes_values_text = _routes_values_text()
    optional_routes_chart_text = _optional_routes_chart_text()
    whoami_routes_values_text = _whoami_routes_values_text()
    headlamp_routes_values_text = _headlamp_routes_values_text()
    grafana_routes_values_text = _grafana_routes_values_text()
    wiredoor_gateway_routes_values_text = _wiredoor_gateway_routes_values_text()
    traefik_values_text = _traefik_values_text()
    wiredoor_gateway_values_text = _wiredoor_gateway_values_text()
    traefik_secretstore_text = _traefik_dashboard_secretstore_text()
    traefik_externalsecret_text = _traefik_dashboard_externalsecret_text()
    wiredoor_secretstore_text = _wiredoor_gateway_secretstore_text()
    wiredoor_externalsecret_text = _wiredoor_gateway_externalsecret_text()

    assert 'whoami:' not in routes_values_text
    assert 'headlamp:' not in routes_values_text
    assert 'grafana:' not in routes_values_text
    assert 'enabled: trueß∑' not in traefik_values_text
    assert 'enabled: true' in traefik_values_text
    assert 'existingSecret: wiredoor-gateway' in wiredoor_gateway_values_text
    assert 'token:' not in wiredoor_gateway_values_text
    assert 'argocd.argoproj.io/sync-wave: "0"' in traefik_app_text
    assert 'argocd.argoproj.io/sync-wave: "1"' in routes_app_text
    assert 'kind: Application' in whoami_app_text
    assert 'kind: Application' in headlamp_app_text
    assert 'path: gitops/optional-routes' in whoami_routes_app_text
    assert 'whoami-routes' in whoami_routes_app_text
    assert 'path: gitops/optional-routes' in headlamp_routes_app_text
    assert 'headlamp-routes' in headlamp_routes_app_text
    assert 'argocd.argoproj.io/sync-wave: "0"' in wiredoor_gateway_secret_app_text
    assert 'argocd.argoproj.io/sync-wave: "1"' in wiredoor_gateway_app_text
    assert 'argocd.argoproj.io/sync-wave: "2"' in WIREDOOR_GATEWAY_ROUTES_APP.read_text(encoding="utf-8")
    assert 'kind: IngressRoute' in optional_routes_chart_text
    assert 'ingressRoutes:' in whoami_routes_values_text
    assert 'Host(`whoami.bierineenweek.nl`)' in whoami_routes_values_text
    assert 'Host(`headlamp.bierineenweek.nl`)' in headlamp_routes_values_text
    assert 'Host(`grafana.bierineenweek.nl`)' in grafana_routes_values_text
    assert 'Host(`argocd.bierineenweek.nl`)' in wiredoor_gateway_routes_values_text
    assert 'kind: SecretStore' in traefik_secretstore_text
    assert 'name: traefik-dashboard-fields' in traefik_secretstore_text
    assert 'twinbox/global/traefik-dashboard' in traefik_secretstore_text
    assert 'kind: ExternalSecret' in traefik_externalsecret_text
    assert 'name: traefik-dashboard-auth' in traefik_externalsecret_text
    assert 'secretKey: users' in traefik_externalsecret_text
    assert 'kind: SecretStore' in wiredoor_secretstore_text
    assert 'name: wiredoor-gateway-fields' in wiredoor_secretstore_text
    assert 'http://192.168.2.54:8080/api/secret-values/{{ .remoteRef.key }}?source=login&property={{ .remoteRef.property }}' in wiredoor_secretstore_text
    assert '$.value' in wiredoor_secretstore_text
    assert 'kind: ExternalSecret' in wiredoor_externalsecret_text
    assert 'name: wiredoor-gateway' in wiredoor_externalsecret_text
    assert 'property: username' in wiredoor_externalsecret_text
    assert 'property: password' in wiredoor_externalsecret_text
    assert 'secretKey: TOKEN' in wiredoor_externalsecret_text


def test_grafana_admin_credentials_are_vaultwarden_backed():
    grafana_values_text = _grafana_values_text()
    grafana_secret_app_text = _grafana_secret_app_text()
    grafana_app_text = _grafana_app_text()
    grafana_secretstore_text = _grafana_secretstore_text()
    grafana_externalsecret_text = _grafana_externalsecret_text()

    assert 'adminPassword:' not in grafana_values_text
    assert 'existingSecret: grafana-admin' in grafana_values_text
    assert 'userKey: admin-user' in grafana_values_text
    assert 'passwordKey: admin-password' in grafana_values_text
    assert 'argocd.argoproj.io/sync-wave: "0"' in grafana_secret_app_text
    assert 'argocd.argoproj.io/sync-wave: "1"' in grafana_app_text
    assert 'kind: Application' in grafana_secret_app_text
    assert 'grafana-secret' in grafana_secret_app_text
    assert 'kind: SecretStore' in grafana_secretstore_text
    assert 'object/item/ea9461a9-bffa-4a30-9cc0-3585b78360b1' in grafana_secretstore_text
    assert 'kind: ExternalSecret' in grafana_externalsecret_text
    assert 'admin-user' in grafana_externalsecret_text
    assert 'admin-password' in grafana_externalsecret_text


def test_talos_module_is_vm_only_and_keeps_planned_outputs():
    main_text = _module_text()
    outputs_text = _module_outputs_text()
    assert 'resource "proxmox_virtual_environment_vm" "node"' in main_text
    assert 'resource "proxmox_virtual_environment_file" "talos_nocloud"' in main_text
    assert 'for_each     = local.talos_image_nodes' in main_text
    assert 'content_type = "iso"' in main_text
    assert 'source_file {' in main_text
    assert 'path      = var.talos_image_local_path' in main_text
    assert 'file_name = "talos-${var.talos_image_cache_key}.iso"' in main_text
    assert 'node_name    = each.value' in main_text
    assert 'machine   = "q35"' not in main_text
    assert 'boot_order = var.boot_from_disk ? ["virtio0"] : ["ide2", "virtio0"]' in main_text
    assert 'cdrom {' in main_text
    assert 'dynamic "cdrom"' not in main_text
    assert 'for_each = var.boot_from_disk ? [] : [1]' not in main_text
    assert 'validation {' not in _module_variables_text()
    assert 'vm_host_map = var.vm_node_map' in main_text
    assert 'merge(' not in main_text
    assert 'file_id   = proxmox_virtual_environment_file.talos_nocloud[local.vm_host_map[each.key]].id' in main_text
    assert 'node_name = local.vm_host_map[each.key]' in main_text
    assert 'file_id      = proxmox_virtual_environment_file.talos_nocloud.id' not in main_text
    assert 'file_format  = "raw"' not in main_text
    assert 'agent {' in main_text
    assert 'wait_for_ip {' in main_text
    assert 'ipv4 = true' in main_text
    assert 'reboot_after_update = false' in main_text
    assert 'type = "std"' in main_text
    assert 'talos_machine_configuration_apply' not in main_text
    assert 'talos_machine_bootstrap' not in main_text
    assert 'talos_cluster_kubeconfig' not in main_text
    assert 'output "controlplane_vm_ids"' in outputs_text
    assert 'output "worker_vm_ids"' in outputs_text
    assert 'output "controlplane_ipv4_addresses"' in outputs_text
    assert 'output "worker_ipv4_addresses"' in outputs_text
    assert 'output "kubeconfig"' not in outputs_text
