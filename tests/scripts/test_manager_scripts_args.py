import os
import subprocess
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
APPLY_CLUSTER_SCRIPT = REPO_ROOT / "scripts" / "manager" / "apply-cluster.sh"
BOOTSTRAP_SCRIPT = REPO_ROOT / "scripts" / "manager" / "bootstrap-talos.sh"
PROVISION_NODES_SCRIPT = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "provision-nodes" / "run.sh"
)
MODULE_MAIN = REPO_ROOT / "infra" / "opentofu" / "talos-proxmox" / "main.tf"
MODULE_OUTPUTS = REPO_ROOT / "infra" / "opentofu" / "talos-proxmox" / "outputs.tf"
INSTALL_SECRET_SYNC_SCRIPT = (
    REPO_ROOT / "scripts" / "manager" / "install-secret-sync.sh"
)
OPENBAO_SECRET_SYNC_HELPER = (
    REPO_ROOT / "scripts" / "manager" / "sync-openbao-global-secret.sh"
)
ARGO_MANAGER_SCRIPT = REPO_ROOT / "scripts" / "manager" / "install-argocd.sh"
APPLY_ARGO_APP_SCRIPT = (
    REPO_ROOT / "scripts" / "manager" / "apply-argocd-application.sh"
)
RENDER_CILIUM_SCRIPT = REPO_ROOT / "scripts" / "manager" / "render-cilium-manifest.sh"
ARGO_STEP_SCRIPT = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-argocd" / "run.sh"
)
ARGO_STEP_MANIFEST = (
    REPO_ROOT
    / "categories"
    / "talos-cluster"
    / "steps"
    / "install-argocd"
    / "step.yaml"
)
CILIUM_VALUES_FILE = REPO_ROOT / "config" / "cilium-values.yaml"
LONGHORN_STEP_SCRIPT = (
    REPO_ROOT
    / "categories"
    / "talos-cluster"
    / "steps"
    / "install-longhorn-storage"
    / "run.sh"
)
LONGHORN_STEP_MANIFEST = (
    REPO_ROOT
    / "categories"
    / "talos-cluster"
    / "steps"
    / "install-longhorn-storage"
    / "step.yaml"
)
LONGHORN_HELPER_SCRIPT = (
    REPO_ROOT / "scripts" / "manager" / "install-longhorn-storage.sh"
)
TRAEFIK_STEP_SCRIPT = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-traefik" / "run.sh"
)
TRAEFIK_STEP_MANIFEST = (
    REPO_ROOT
    / "categories"
    / "talos-cluster"
    / "steps"
    / "install-traefik"
    / "step.yaml"
)
CLOUDFLARE_STEP_MANIFEST = (
    REPO_ROOT
    / "categories"
    / "talos-cluster"
    / "steps"
    / "configure-cloudflare-dns"
    / "step.yaml"
)
AUTHENTIK_STEP_MANIFEST = (
    REPO_ROOT
    / "categories"
    / "talos-cluster"
    / "steps"
    / "install-authentik-idp"
    / "step.yaml"
)
AUTHENTIK_STEP_SCRIPT = (
    REPO_ROOT
    / "categories"
    / "talos-cluster"
    / "steps"
    / "install-authentik-idp"
    / "run.sh"
)
CREATE_USERS_STEP_MANIFEST = (
    REPO_ROOT
    / "categories"
    / "talos-cluster"
    / "steps"
    / "create-users-and-groups"
    / "step.yaml"
)
CHOOSE_INGRESS_ROUTE_STEP_MANIFEST = (
    REPO_ROOT
    / "categories"
    / "talos-cluster"
    / "steps"
    / "choose-ingress-route"
    / "step.yaml"
)
WHOAMI_STEP_MANIFEST = (
    REPO_ROOT
    / "categories"
    / "talos-cluster"
    / "steps"
    / "install-whoami"
    / "step.yaml"
)
HEADLAMP_STEP_MANIFEST = (
    REPO_ROOT
    / "categories"
    / "talos-cluster"
    / "steps"
    / "install-headlamp"
    / "step.yaml"
)
GRAFANA_STEP_MANIFEST = (
    REPO_ROOT
    / "categories"
    / "talos-cluster"
    / "steps"
    / "install-grafana"
    / "step.yaml"
)
WIREDOOR_GATEWAY_STEP_MANIFEST = (
    REPO_ROOT
    / "categories"
    / "talos-cluster"
    / "steps"
    / "install-wiredoor-gateway"
    / "step.yaml"
)
WIREDOOR_BASTION_STEP_MANIFEST = (
    REPO_ROOT
    / "categories"
    / "talos-cluster"
    / "steps"
    / "provision-wiredoor-bastion"
    / "step.yaml"
)
ARGO_BOOTSTRAP_SCRIPT = REPO_ROOT / "gitops" / "install.sh"
LONGHORN_APP = REPO_ROOT / "gitops" / "apps" / "longhorn.yaml"
TRAEFIK_APP = REPO_ROOT / "gitops" / "apps" / "traefik.yaml"
WHOAMI_APP = REPO_ROOT / "gitops" / "apps" / "whoami.yaml"
HEADLAMP_APP = REPO_ROOT / "gitops" / "apps" / "headlamp.yaml"
GRAFANA_APP = REPO_ROOT / "gitops" / "apps" / "grafana.yaml"
WIREDOOR_GATEWAY_APP = REPO_ROOT / "gitops" / "apps" / "wiredoor-gateway.yaml"
WHOAMI_DEPLOYMENT = REPO_ROOT / "gitops" / "platform" / "whoami" / "deployment.yaml"
HEADLAMP_VALUES = REPO_ROOT / "gitops" / "values" / "headlamp.yaml"
LONGHORN_VALUES = REPO_ROOT / "gitops" / "values" / "longhorn.yaml"
TRAEFIK_VALUES = REPO_ROOT / "gitops" / "values" / "traefik.yaml"
WIREDOOR_GATEWAY_VALUES = REPO_ROOT / "gitops" / "values" / "wiredoor-gateway.yaml"
GRAFANA_VALUES = REPO_ROOT / "gitops" / "values" / "grafana.yaml"
TRAEFIK_DASHBOARD_EXTERNALSECRET = (
    REPO_ROOT
    / "gitops"
    / "platform"
    / "traefik"
    / "traefik-dashboard-externalsecret.yaml"
)
WHOAMI_INGRESSROUTE = REPO_ROOT / "gitops" / "platform" / "whoami" / "ingressroute.yaml"
HEADLAMP_INGRESSROUTE = (
    REPO_ROOT / "gitops" / "platform" / "headlamp" / "ingressroute.yaml"
)
GRAFANA_EXTERNALSECRET = (
    REPO_ROOT / "gitops" / "platform" / "grafana" / "externalsecret.yaml"
)
GRAFANA_INGRESSROUTE = (
    REPO_ROOT / "gitops" / "platform" / "grafana" / "ingressroute.yaml"
)
WIREDOOR_GATEWAY_EXTERNALSECRET = (
    REPO_ROOT / "gitops" / "platform" / "wiredoor-gateway" / "externalsecret.yaml"
)
WIREDOOR_GATEWAY_INGRESSROUTE = (
    REPO_ROOT / "gitops" / "platform" / "wiredoor-gateway" / "ingressroute.yaml"
)
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
    return (
        REPO_ROOT / "infra" / "opentofu" / "talos-proxmox" / "variables.tf"
    ).read_text(encoding="utf-8")


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


def _apply_argocd_application_text() -> str:
    return APPLY_ARGO_APP_SCRIPT.read_text(encoding="utf-8")


def _cilium_render_text() -> str:
    return RENDER_CILIUM_SCRIPT.read_text(encoding="utf-8")


def _cilium_values_text() -> str:
    return CILIUM_VALUES_FILE.read_text(encoding="utf-8")


def _pinned_defaults_text() -> str:
    return PINNED_DEFAULTS.read_text(encoding="utf-8")


def _argo_step_manifest_text() -> str:
    return ARGO_STEP_MANIFEST.read_text(encoding="utf-8")


def _longhorn_step_text() -> str:
    return LONGHORN_STEP_SCRIPT.read_text(encoding="utf-8")


def _longhorn_step_manifest_text() -> str:
    return LONGHORN_STEP_MANIFEST.read_text(encoding="utf-8")


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


def _longhorn_values_text() -> str:
    return LONGHORN_VALUES.read_text(encoding="utf-8")


def _wiredoor_gateway_values_text() -> str:
    return WIREDOOR_GATEWAY_VALUES.read_text(encoding="utf-8")


def _traefik_dashboard_externalsecret_text() -> str:
    return TRAEFIK_DASHBOARD_EXTERNALSECRET.read_text(encoding="utf-8")


def _wiredoor_gateway_externalsecret_text() -> str:
    return WIREDOOR_GATEWAY_EXTERNALSECRET.read_text(encoding="utf-8")


def _grafana_values_text() -> str:
    return GRAFANA_VALUES.read_text(encoding="utf-8")


def _traefik_app_text() -> str:
    return TRAEFIK_APP.read_text(encoding="utf-8")


def _wiredoor_gateway_app_text() -> str:
    return WIREDOOR_GATEWAY_APP.read_text(encoding="utf-8")


def _grafana_externalsecret_text() -> str:
    return GRAFANA_EXTERNALSECRET.read_text(encoding="utf-8")


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
        proc = subprocess.run(
            cmd, env=os.environ.copy(), capture_output=True, text=True
        )
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
    assert 'PROXMOX_UPLOAD_MAX_ATTEMPTS="${PROXMOX_UPLOAD_MAX_ATTEMPTS:-5}"' in text
    assert "reboot_talos_node() {" not in text
    assert "talosctl reboot \\" not in text
    assert "Rebooting Talos nodes after disk-first switch" not in text
    assert (
        "Disk-first boot order applied; Talos nodes will boot from disk on the next cold VM restart"
        in text
    )
    assert "command -v talosctl" in text
    assert "export TF_IN_AUTOMATION=1" in text
    assert "export NO_COLOR=1" in text
    assert "command -v curl" in text
    assert "resolve_talos_image_assets()" in text
    assert "scripts/get-talos-image-factory.sh" in text
    assert "PINNED_TALOS_IMAGE_SCHEMATIC" not in text
    assert '--preset "${TALOS_IMAGE_PRESET:-qemu-guest-agent}"' not in text
    assert "TALOS_IMAGE_PRESET" in text
    assert "talosctl apply-config \\" in text
    assert '--endpoints "$ip" \\' in text
    assert "Insecure Talos apply failed for ${ip}; retrying without --insecure" in text
    assert "AlreadyExists desc = etcd data directory is not empty" in text
    assert "talosctl bootstrap" in text
    assert 'bootstrap_mode = "dhcp-first"' in text
    assert '"/image/default/"' not in text
    assert '!= "default"' not in text
    assert "TALOS_IMAGE_FACTORY_URL:-" not in text
    assert "TALOS_IMAGE_INSTALLER=" in text
    assert "TALOS_IMAGE_DOWNLOAD_URL=" in text
    assert "download_talos_image()" in text
    assert (
        'talos_image_local_path="$image_cache_dir/talos-${image_cache_key}.iso"' in text
    )
    assert 'talos_image_file_name="talos-${image_cache_key}.iso"' in text
    assert "proxmox_api_login()" in text
    assert "proxmox_upload_talos_image()" in text
    assert "proxmox_verify_talos_image()" in text
    assert "proxmox_talos_image_present()" in text
    assert "upload_talos_image_to_nodes()" in text
    assert "remove_legacy_talos_file_state()" in text
    assert "Uploading Talos ISO to Proxmox nodes:" in text
    assert "Uploaded Talos ISO to ${node}/${datastore}" in text
    assert "Talos ISO not visible after upload on ${node}/${datastore}" in text
    assert (
        "Talos ISO already present on ${node}/${FILE_DATASTORE}: ${image_name}" in text
    )
    assert "Removing legacy Talos ISO resources from OpenTofu state:" in text
    assert 'state rm "${legacy_addresses[@]}"' in text
    assert "controlplane_ipv4_addresses.value" in text
    assert "worker_ipv4_addresses.value" in text
    assert "flatten_ipv4_candidates" in text or "flatten | .[]" in text
    assert 'select(startswith("10.244.") | not)' in text
    assert "TF_VAR_proxmox_endpoint" in text
    assert "TF_VAR_proxmox_username" in text
    assert "TF_VAR_proxmox_password" in text
    assert (
        'PROXMOX_PASSWORD="${PROXMOX_PASSWORD:-${TF_VAR_proxmox_password:-}}" '
        not in text
    )
    assert (
        'PROXMOX_PASSWORD="${PROXMOX_PASSWORD:-${TF_VAR_proxmox_password:-}}"' in text
    )
    assert (
        "Missing environment variable: PROXMOX_PASSWORD or TF_VAR_proxmox_password"
        in text
    )
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
    assert "content=iso" in text
    assert "curl -ksS --show-error" in text
    assert "CSRFPreventionToken" in text
    assert "access/ticket" in text
    assert "storage/${datastore}/content" in text
    assert "Failed to obtain Proxmox API ticket" in text
    assert "retrying in ${delay}s" in text
    assert "failed permanently" in text
    assert "failed after ${PROXMOX_UPLOAD_MAX_ATTEMPTS} attempts" in text
    assert 'expected_volid="${datastore}:iso/${image_name}"' in text
    assert 'select(.volid == $volid and .content == "iso")' in text


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
    assert 'sed \'s/^/        /\' "$cilium_manifest_file"' in text
    assert 'wait_for_kubernetes_rollout "daemonset/cilium" "kube-system" "Cilium DaemonSet"' in text
    assert 'wait_for_kubernetes_rollout "deployment/cilium-operator" "kube-system" "Cilium operator"' in text
    assert 'wait_for_kubernetes_rollout "deployment/coredns" "kube-system" "CoreDNS"' in text
    assert "kube-proxy daemonset should not exist in kube-proxy-free mode" in text
    assert "helm repo add cilium https://helm.cilium.io" in helper_text
    assert "helm repo update" in helper_text
    assert "--include-crds" in helper_text
    assert "PINNED_CILIUM_CHART_VERSION" in helper_text
    assert "PINNED_CILIUM_CHART_VERSION=1.18.8" in pinned_defaults_text
    assert "ipam:" in values_text
    assert "mode: kubernetes" in values_text
    assert "kubeProxyReplacement: true" in values_text
    assert "k8sServiceHost: localhost" in values_text
    assert "k8sServicePort: 7445" in values_text
    assert "cgroup:" in values_text
    assert "hostRoot: /sys/fs/cgroup" in values_text
    assert "operator:" in values_text
    assert "replicas: 1" in values_text
    assert "SYS_MODULE" not in values_text


def test_longhorn_step_installs_via_argocd_and_waits_for_health():
    step_text = _longhorn_step_text()
    step_manifest_text = _longhorn_step_manifest_text()
    helper_text = _longhorn_helper_text()
    longhorn_values_text = _longhorn_values_text()

    assert "title: Install Longhorn Storage" in step_manifest_text
    assert "order: 14" in step_manifest_text
    assert (
        "summary: Apply the Longhorn GitOps application, make its storage class the cluster default, and wait for it to become available."
        in step_manifest_text
    )
    assert "depends_on:" in step_manifest_text
    assert "  - install-argocd" in step_manifest_text
    assert "runner:" in step_manifest_text
    assert "KUBECONFIG_FILE:" in step_manifest_text
    assert "item: kubeconfig" in step_manifest_text
    assert (
        "script: categories/talos-cluster/steps/install-longhorn-storage/run.sh"
        in step_manifest_text
    )
    assert (
        "cluster_json=\"$(printf '%s' \"$STEP_CONTEXT_JSON\" | jq -c '.cluster')\""
        in step_text
    )
    assert 'TWINBOX_CLUSTER_ID="$cluster_id"' in step_text
    assert 'TWINBOX_CLUSTER_INSTANCE_ID="$cluster_instance_id"' in step_text
    assert 'KUBE_API_SERVER="https://${controlplane_ip}:6443"' in step_text
    assert 'bash "$WORKSPACE_ROOT/scripts/manager/install-longhorn-storage.sh"' in step_text
    assert (
        'WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"'
        in step_text
    )
    assert 'manifest_path="$WORKSPACE_ROOT/gitops/apps/longhorn.yaml"' in helper_text
    assert "Installing Longhorn through Argo CD" in helper_text
    assert (
        'bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \\'
        in helper_text
    )
    assert '--application "longhorn"' in helper_text
    assert "wait_for_storage_class" in helper_text
    assert "StorageClass/${storage_class} is available" in helper_text
    assert "make_storage_class_default" in helper_text
    assert (
        "Marking StorageClass/${storage_class} as the default storage class"
        in helper_text
    )
    assert "storageclass.kubernetes.io/is-default-class" in helper_text
    assert "storageclass.beta.kubernetes.io/is-default-class" in helper_text
    assert "is not the only default storage class" in helper_text
    assert "preUpgradeChecker:" in longhorn_values_text
    assert "jobEnabled: false" in longhorn_values_text
    assert "taintToleration:" in longhorn_values_text


def test_apply_cluster_renders_dhcp_first_talos_flow_and_tracks_iac_paths():
    text = _apply_cluster_text()
    assert (
        'helper_output="$("$WORKSPACE_ROOT/scripts/get-talos-image-factory.sh"' in text
    )
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
    assert "Downloading Talos ISO" in text
    assert '--arg talos_image_local_path "$talos_image_local_path"' in text
    assert "nodes: $nodes" in text
    assert "planned_controlplane_ips" in text
    assert "discovered_controlplane_ips" in text
    assert "generate_talos_configs()" in text
    assert "discover_node_ip()" in text
    assert "Guest agent reported ${label} at ${candidate}" in text
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


def test_provision_nodes_step_returns_refs_not_kubeconfig_paths():
    text = PROVISION_NODES_SCRIPT.read_text(encoding="utf-8")
    assert "secret_refs: .metadata.secret_refs" in text
    assert "kubeconfig_path" not in text
    assert "Using ${effective_vm_node_map_source} vm_node_map:" in text
    assert (
        'VM_NODE_MAP="$effective_vm_node_map" bash scripts/manager/apply-cluster.sh \\'
        in text
    )
    assert '--vm-node-map "$effective_vm_node_map"' in text


def test_manager_worker_image_includes_talos_image_factory_helper():
    text = (REPO_ROOT / "manager-worker" / "Dockerfile").read_text(encoding="utf-8")
    assert "PINNED_TALOS_VERSION" in text
    assert "talosctl-linux-amd64" in text
    assert "COPY lib ./lib" in text
    assert (
        "apt-get install -y --no-install-recommends bash ca-certificates curl jq openssl tar xz-utils sudo"
        in text
    )
    assert (
        "COPY scripts/get-talos-image-factory.sh ./scripts/get-talos-image-factory.sh"
        in text
    )
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
    helper_text = (
        REPO_ROOT / "scripts" / "manager" / "openbao-secret-sync.sh"
    ).read_text(encoding="utf-8")
    assert 'source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"' in text
    assert "scripts/manager/apply-argocd-application.sh" in text
    assert '--manifest "$WORKSPACE_ROOT/gitops/apps/external-secrets.yaml"' in text
    assert '--application "external-secrets"' in text
    assert "mktemp" in text
    assert "helm:" in text
    assert "values: |" in text
    assert 'sed \'s/^/          /\' "$OPENBAO_VALUES_FILE"' in text
    assert '--application "openbao"' in text
    assert '--no-wait' in text
    assert 'repoURL: https://openbao.github.io/openbao-helm' in text
    assert 'chart: openbao' in text
    assert 'targetRevision: "0.26.2"' in text
    assert "gitops/apps/openbao.yaml" not in text
    assert "openbao_render_values_file" in text
    assert "openbao_seed_management_bootstrap_files" in text
    assert "openbao_seed_release_secret" in text
    assert 'openbao_initialize_if_needed "$openbao_pod"' in text
    assert 'openbao_configure_auth_and_policy "$openbao_pod"' in text
    assert 'openbao_seed_secret_paths "$openbao_pod"' in text
    assert "openbao_apply_cluster_secret_store" in text
    assert "openbao_apply_bootstrap_external_secret" in text
    assert 'openbao_wait_for_secret "$TARGET_SECRET_NAME" "$TARGET_NAMESPACE"' in text
    assert "kind: ClusterSecretStore" not in text
    assert "bw " not in text
    assert "KUBECONFIG_FILE is required" in text


def test_openbao_secret_sync_helper_uses_shared_library_and_port_forward_writeback():
    text = _openbao_secret_sync_helper_text()
    assert 'source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"' in text
    assert (
        "Usage: sync-openbao-global-secret.sh --secret-name NAME --json-file PATH"
        in text
    )
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

    assert "Usage: $0 --manifest PATH --application NAME [--no-wait]" in text
    assert "cluster_resource_profile()" in text
    assert "namespace_resource_baseline()" in text
    assert "extract_destination_namespace()" in text
    assert "Applying namespace resource baseline to" in text
    assert "kind: LimitRange" in text
    assert "defaultRequest:" in text
    assert "default:" in text
    assert "printf '%s\\n' \"$rendered_manifest\" | kubectl apply --validate=false -f -" in text
    assert 'kubectl -n argocd get application "$application" -o json' in text
    assert "Application/${application} is Synced and Healthy" in text
    assert "Application/${application} is Synced and has no unhealthy resources" in text
    assert "has_unhealthy_resources()" in text
    assert "--no-wait" in text


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
    assert 'application: $application' in text


def test_argo_bootstrap_script_installs_argocd_without_root_application_tree():
    text = _argo_bootstrap_text()
    wait_section = text.split("local resources=(")[1].split(
        'for resource in "${resources[@]}"; do'
    )[0]
    assert "Creating argocd namespace" in text
    assert "Installing Argo CD" in text
    assert (
        "kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply --validate=false -f -"
        in text
    )
    assert (
        "kubectl apply --server-side --force-conflicts --validate=false -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.4/manifests/install.yaml"
        in text
    )
    assert "control_plane_tolerations" in text
    assert (
        "Patching statefulset/argocd-application-controller for control-plane tolerations"
        in text
    )
    assert "kubectl -n argocd patch" in text
    assert "patch_argocd_workload_probes()" in text
    assert "Patching ${resource} liveness probe for single-node bootstrap" in text
    assert "--type strategic -p" in text
    assert '"initialDelaySeconds":300' in text
    assert "patch_argocd_repo_server_copyutil()" in text
    assert (
        "Patching deployment/argocd-repo-server copyutil init container for idempotent startup"
        in text
    )
    assert (
        "/bin/ln -sfn /var/run/argocd/argocd /var/run/argocd/argocd-cmp-server" in text
    )
    assert "wait_for_available()" in text
    assert "Waiting for ${resource} to become available" in text
    assert (
        'kubectl -n argocd wait --for=condition=Available "$resource" --timeout=900s'
        in text
    )
    assert "wait_for_statefulset_rollout()" in text
    assert 'kubectl -n argocd rollout status "$resource" --timeout=900s' in text
    assert (
        'wait_for_statefulset_rollout "statefulset/argocd-application-controller"'
        in text
    )
    assert "statefulset/argocd-application-controller" not in wait_section
    assert "wait_for_application_ready()" not in text
    assert "wait_for_root_applications()" not in text
    assert "deployment/argocd-applicationset-controller" in text
    assert "deployment/argocd-repo-server" in text
    assert "statefulset/argocd-application-controller" in text
    assert "Applying core Argo root application" not in text
    assert "gitops/argocd/root.yaml" not in text


def test_bootstrap_apps_tolerate_single_node_control_plane():
    whoami_text = _whoami_deployment_text()
    headlamp_text = _headlamp_values_text()

    assert "tolerations:" in whoami_text
    assert "node-role.kubernetes.io/control-plane" in whoami_text
    assert "node-role.kubernetes.io/master" in whoami_text
    assert "tolerations:" in headlamp_text
    assert "node-role.kubernetes.io/control-plane" in headlamp_text
    assert "node-role.kubernetes.io/master" in headlamp_text


def test_install_argocd_step_bootstraps_argocd_without_cni_adoption():
    text = _argo_step_manifest_text()

    assert "summary: Install Argo CD so the remaining platform services can be managed declaratively." in text
    assert "order: 12" in text
    assert "depends_on:" in text
    assert "  - provision-nodes" in text
    assert "Talos/Cilium bootstrap" in text
    assert "Talos networking layer" not in text
    assert "root application tree" not in text


def test_app_step_manifests_chain_the_linear_gitops_flow():
    argocd_text = ARGO_STEP_MANIFEST.read_text(encoding="utf-8")
    traefik_text = TRAEFIK_STEP_MANIFEST.read_text(encoding="utf-8")
    authentik_run_text = _authentik_step_text()
    cloudflare_text = CLOUDFLARE_STEP_MANIFEST.read_text(encoding="utf-8")
    choose_ingress_text = CHOOSE_INGRESS_ROUTE_STEP_MANIFEST.read_text(
        encoding="utf-8"
    )
    whoami_text = WHOAMI_STEP_MANIFEST.read_text(encoding="utf-8")
    headlamp_text = HEADLAMP_STEP_MANIFEST.read_text(encoding="utf-8")
    grafana_text = GRAFANA_STEP_MANIFEST.read_text(encoding="utf-8")
    wiredoor_text = WIREDOOR_GATEWAY_STEP_MANIFEST.read_text(encoding="utf-8")
    wiredoor_bastion_text = WIREDOOR_BASTION_STEP_MANIFEST.read_text(
        encoding="utf-8"
    )

    assert "order: 12" in argocd_text
    assert "provision-nodes" in argocd_text
    assert "install-flannel" not in argocd_text

    assert "order: 16" in traefik_text
    assert "install-secret-sync" in traefik_text

    assert "order: 22" in AUTHENTIK_STEP_MANIFEST.read_text(encoding="utf-8")
    assert "order: 23" in CREATE_USERS_STEP_MANIFEST.read_text(encoding="utf-8")
    assert "order: 21" in choose_ingress_text
    assert "type: config" in choose_ingress_text
    assert "value: wiredoor" in choose_ingress_text
    assert "value: metallb" in choose_ingress_text
    assert "depends_on:" in choose_ingress_text
    assert "dns_domain" in choose_ingress_text
    assert "DNS Domain" in choose_ingress_text
    assert "TST always uses app.tst.example.org" in choose_ingress_text
    assert "PRD always uses app.example.com" in choose_ingress_text

    assert "order: 31" in cloudflare_text
    assert "choose-ingress-route" in cloudflare_text
    assert "provision-wiredoor-bastion" in cloudflare_text

    assert "order: 32" in wiredoor_text
    assert "install-grafana" in wiredoor_text
    assert "choose-ingress-route" in wiredoor_text
    assert "configure-wiredoor-ingress" in wiredoor_text
    assert "KUBECONFIG_FILE:" in wiredoor_text
    assert "item: kubeconfig" in wiredoor_text
    assert (
        "script: categories/talos-cluster/steps/install-wiredoor-gateway/run.sh"
        in wiredoor_text
    )

    assert "order: 30" in wiredoor_bastion_text
    assert "choose-ingress-route" in wiredoor_bastion_text
    assert "ingress_route: wiredoor" in wiredoor_bastion_text

    assert "cluster_dns_domain" in authentik_run_text
    assert "public_zone_name" in authentik_run_text
    assert "cluster-public-zone.sh" in authentik_run_text
    assert "https://authentik.${public_zone_name}" in authentik_run_text
    assert "kubectl create namespace authentik --dry-run=client -o yaml | kubectl apply -f -" in authentik_run_text
    assert "gitops/platform/authentik/externalsecret.yaml" in authentik_run_text
    assert "gitops/platform/authentik/ingressroute.yaml" in authentik_run_text
    assert "AUTHENTIK_POSTGRESQL__HOST" in authentik_run_text
    assert "AUTHENTIK_POSTGRESQL__PORT" in authentik_run_text
    assert "AUTHENTIK_POSTGRESQL__NAME" in authentik_run_text
    assert "AUTHENTIK_POSTGRESQL__USER" in authentik_run_text
    assert "AUTHENTIK_POSTGRESQL__USERNAME" in authentik_run_text
    assert "AUTHENTIK_POSTGRESQL__DISABLE_SERVER_SIDE_CURSORS" in authentik_run_text
    assert "AUTHENTIK_POSTGRESQL__CONN_MAX_AGE" in authentik_run_text
    assert "rollout restart deployment" in authentik_run_text
    assert "rollout status deployment" in authentik_run_text
    assert "twinbox_public_zone_name" in authentik_run_text
    assert 'authentik_host="https://authentik.${public_zone_name}"' in authentik_run_text
    assert (
        "Could not determine Authentik host; set DNS domain in the ingress selection step"
        in authentik_run_text
    )

    cloudflare_tunnel_run_text = (
        REPO_ROOT
        / "categories"
        / "talos-cluster"
        / "steps"
        / "configure-cloudflare-tunnel"
        / "run.sh"
    ).read_text(encoding="utf-8")
    assert 'curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${cf_account_id}/cfd_tunnel/${cf_tunnel_id}/token"' in cloudflare_tunnel_run_text
    assert "jq -r '.success // false'" in cloudflare_tunnel_run_text
    assert "jq -r '.result // empty'" in cloudflare_tunnel_run_text
    assert "cluster_dns_domain" in cloudflare_tunnel_run_text
    assert "cluster-public-zone.sh" in cloudflare_tunnel_run_text
    assert "twinbox_public_zone_name" in cloudflare_tunnel_run_text
    assert 'echo "[$(date \'+%Y-%m-%d %H:%M:%S\')] Public zone name: $public_zone_name"' in cloudflare_tunnel_run_text
    assert '\\"name\\":\\"*.${public_zone_name}\\"' in cloudflare_tunnel_run_text
    assert "already have a tunnel with this name" in cloudflare_tunnel_run_text
    assert ".result.Token" not in cloudflare_tunnel_run_text
    assert "cluster-hostnames" in cloudflare_tunnel_run_text
    assert "platform-ingress.yaml" in cloudflare_tunnel_run_text
    assert "cluster-config.yaml" in cloudflare_tunnel_run_text

    cloudflare_dns_run_text = (
        REPO_ROOT
        / "categories"
        / "talos-cluster"
        / "steps"
        / "configure-cloudflare-dns"
        / "run.sh"
    ).read_text(encoding="utf-8")
    assert "cluster-public-zone.sh" in cloudflare_dns_run_text
    assert "twinbox_public_zone_name" in cloudflare_dns_run_text
    assert "Public zone name:" in cloudflare_dns_run_text
    assert "ZONE_NAME" in cloudflare_dns_run_text
    assert "cluster-hostnames" in cloudflare_dns_run_text

    assert "order: 34" in whoami_text
    assert "install-traefik" in whoami_text
    assert "script: categories/talos-cluster/steps/install-whoami/run.sh" in whoami_text

    assert "order: 35" in headlamp_text
    assert "install-whoami" in headlamp_text
    assert (
        "script: categories/talos-cluster/steps/install-headlamp/run.sh"
        in headlamp_text
    )

    assert "order: 36" in grafana_text
    assert "install-headlamp" in grafana_text
    assert (
        "script: categories/talos-cluster/steps/install-grafana/run.sh" in grafana_text
    )


def test_gitops_app_manifests_and_platform_routes_are_openbao_backed():
    longhorn_app_text = LONGHORN_APP.read_text(encoding="utf-8")
    external_secrets_app_text = (
        REPO_ROOT / "gitops" / "apps" / "external-secrets.yaml"
    ).read_text(encoding="utf-8")
    external_secrets_values_text = (
        REPO_ROOT / "gitops" / "values" / "external-secrets.yaml"
    ).read_text(encoding="utf-8")
    traefik_app_text = _traefik_app_text()
    whoami_app_text = WHOAMI_APP.read_text(encoding="utf-8")
    headlamp_app_text = HEADLAMP_APP.read_text(encoding="utf-8")
    wiredoor_gateway_app_text = _wiredoor_gateway_app_text()
    traefik_values_text = _traefik_values_text()
    wiredoor_gateway_values_text = _wiredoor_gateway_values_text()
    traefik_externalsecret_text = _traefik_dashboard_externalsecret_text()
    wiredoor_externalsecret_text = _wiredoor_gateway_externalsecret_text()
    whoami_ingressroute_text = WHOAMI_INGRESSROUTE.read_text(encoding="utf-8")
    headlamp_ingressroute_text = HEADLAMP_INGRESSROUTE.read_text(encoding="utf-8")
    grafana_ingressroute_text = GRAFANA_INGRESSROUTE.read_text(encoding="utf-8")
    wiredoor_ingressroute_text = WIREDOOR_GATEWAY_INGRESSROUTE.read_text(
        encoding="utf-8"
    )

    assert "chart: longhorn" in longhorn_app_text
    assert "$values/gitops/values/longhorn.yaml" in longhorn_app_text
    assert "ServerSideApply=true" in external_secrets_app_text
    assert "certController:" in external_secrets_values_text
    assert "create: false" in external_secrets_values_text
    assert "enabled: trueß∑" not in traefik_values_text
    assert "enabled: true" in traefik_values_text
    assert "existingSecret: wiredoor-gateway" in wiredoor_gateway_values_text
    assert "token:" not in wiredoor_gateway_values_text
    assert "kind: Application" in whoami_app_text
    assert "kind: Application" in headlamp_app_text
    assert "path: gitops/platform/whoami" in whoami_app_text
    assert "path: gitops/platform/whoami/k8s.yaml" not in whoami_app_text
    assert "path: gitops/platform/whoami/k8s.yaml" not in headlamp_app_text
    assert "path: gitops/platform/wiredoor-gateway" not in wiredoor_gateway_app_text
    assert "Host(`whoami.__ZONE_NAME__`)" in whoami_ingressroute_text
    assert "Host(`headlamp.__ZONE_NAME__`)" in headlamp_ingressroute_text
    assert "Host(`grafana.__ZONE_NAME__`)" in grafana_ingressroute_text
    assert "Host(`argocd.__ZONE_NAME__`)" in wiredoor_ingressroute_text
    assert "kind: Application" in (REPO_ROOT / "gitops" / "apps" / "platform-ingress.yaml").read_text(encoding="utf-8")
    assert "kind: Application" in (REPO_ROOT / "gitops" / "apps" / "cluster-config.yaml").read_text(encoding="utf-8")
    assert "kind: ExternalSecret" in traefik_externalsecret_text
    assert "kind: ClusterSecretStore" in traefik_externalsecret_text
    assert "name: openbao" in traefik_externalsecret_text
    assert "name: traefik-dashboard-auth" in traefik_externalsecret_text
    assert "secretKey: users" in traefik_externalsecret_text
    assert "kind: ExternalSecret" in wiredoor_externalsecret_text
    assert "kind: ClusterSecretStore" in wiredoor_externalsecret_text
    assert "name: openbao" in wiredoor_externalsecret_text
    assert "name: wiredoor-gateway" in wiredoor_externalsecret_text
    assert "property: WIREDOOR_URL" in wiredoor_externalsecret_text
    assert "property: TOKEN" in wiredoor_externalsecret_text
    assert "secretKey: TOKEN" in wiredoor_externalsecret_text


def test_grafana_admin_credentials_are_openbao_backed():
    grafana_values_text = _grafana_values_text()
    grafana_app_text = GRAFANA_APP.read_text(encoding="utf-8")
    grafana_externalsecret_text = _grafana_externalsecret_text()

    assert "adminPassword:" not in grafana_values_text
    assert "existingSecret: grafana-admin" in grafana_values_text
    assert "userKey: admin-user" in grafana_values_text
    assert "passwordKey: admin-password" in grafana_values_text
    assert "path: gitops/platform/grafana" not in grafana_app_text
    assert "kind: ExternalSecret" in grafana_externalsecret_text
    assert "kind: ClusterSecretStore" in grafana_externalsecret_text
    assert "name: openbao" in grafana_externalsecret_text
    assert "admin-user" in grafana_externalsecret_text
    assert "admin-password" in grafana_externalsecret_text


def test_talos_module_is_vm_only_and_keeps_planned_outputs():
    main_text = _module_text()
    outputs_text = _module_outputs_text()
    assert 'resource "proxmox_virtual_environment_vm" "node"' in main_text
    assert (
        'resource "proxmox_virtual_environment_file" "talos_nocloud"' not in main_text
    )
    assert "talos_image_nodes" not in main_text
    assert 'content_type = "iso"' not in main_text
    assert "source_file {" not in main_text
    assert "path      = var.talos_image_local_path" not in main_text
    assert "node_name    = each.value" not in main_text
    assert 'machine   = "q35"' not in main_text
    assert (
        'boot_order = var.boot_from_disk ? ["virtio0"] : ["ide2", "virtio0"]'
        in main_text
    )
    assert "cdrom {" in main_text
    assert 'dynamic "cdrom"' not in main_text
    assert "for_each = var.boot_from_disk ? [] : [1]" not in main_text
    assert "validation {" not in _module_variables_text()
    assert "vm_host_map = var.vm_node_map" in main_text
    assert (
        'talos_image_file_name = "talos-${var.talos_image_cache_key}.iso"' in main_text
    )
    assert (
        'talos_image_file_id   = "${var.file_datastore}:iso/${local.talos_image_file_name}"'
        in main_text
    )
    assert "merge(" not in main_text
    assert "file_id   = local.talos_image_file_id" in main_text
    assert "node_name = local.vm_host_map[each.key]" in main_text
    assert (
        "file_id      = proxmox_virtual_environment_file.talos_nocloud.id"
        not in main_text
    )
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
PROMETHEUS_INGRESSROUTE = (
    REPO_ROOT / "gitops" / "platform" / "prometheus" / "ingressroute.yaml"
)
ALERTMANAGER_CONFIG = (
    REPO_ROOT / "gitops" / "platform" / "prometheus" / "alertmanager-config.yaml"
)
LOKI_APP = REPO_ROOT / "gitops" / "apps" / "loki.yaml"
LOKI_VALUES = REPO_ROOT / "gitops" / "values" / "loki.yaml"
NTFY_APP = REPO_ROOT / "gitops" / "apps" / "ntfy.yaml"
NTFY_VALUES = REPO_ROOT / "gitops" / "values" / "ntfy.yaml"
NTFY_INGRESSROUTE = REPO_ROOT / "gitops" / "platform" / "ntfy" / "ingressroute.yaml"
HOMEPAGE_CONFIGMAP = REPO_ROOT / "gitops" / "platform" / "homepage" / "configmap.yaml"
KUSTOMIZATION = REPO_ROOT / "gitops" / "platform" / "kustomization.yaml"
DATABASES_KUSTOMIZATION = REPO_ROOT / "gitops" / "databases" / "kustomization.yaml"
AUTHENTIK_DB_CLUSTER = REPO_ROOT / "gitops" / "databases" / "authentik" / "cluster.yaml"
AUTHENTIK_DB_STORAGECLASS = (
    REPO_ROOT / "gitops" / "databases" / "longhorn-single-storageclass.yaml"
)


def test_prometheus_argocd_app_uses_kube_prometheus_stack():
    text = PROMETHEUS_APP.read_text(encoding="utf-8")
    assert "kind: Application" in text
    assert "name: prometheus" in text
    assert "chart: kube-prometheus-stack" in text
    assert "prometheus-community.github.io/helm-charts" in text
    assert "$values/gitops/values/prometheus.yaml" in text
    assert "namespace: monitoring" in text


def test_prometheus_values_configures_alertmanager_and_storage():
    text = PROMETHEUS_VALUES.read_text(encoding="utf-8")
    assert "kube-prometheus-stack" not in text
    assert "serviceMonitorSelectorNilUsesHelmValues: false" in text
    assert "alertmanager:" in text
    assert "enabled: true" in text
    assert "configSecret: alertmanager-config" in text
    assert "grafana:" in text
    assert "enabled: false" in text
    assert "storageClassName: longhorn" in text


def test_prometheus_ingressroute_exposes_ui():
    text = PROMETHEUS_INGRESSROUTE.read_text(encoding="utf-8")
    assert "kind: IngressRoute" in text
    assert "Host(`prometheus.__ZONE_NAME__`)" in text
    assert "prometheus-operated" in text
    assert "port: 9090" in text
    assert "webwiredoor" in text


def test_alertmanager_config_routes_to_ntfy():
    text = ALERTMANAGER_CONFIG.read_text(encoding="utf-8")
    assert "name: alertmanager-config" in text
    assert "alertmanager.yaml:" in text
    assert "receiver: 'ntfy'" in text
    assert "name: 'ntfy'" in text
    assert "webhook_configs:" in text
    assert "ntfy.monitoring.svc.cluster.local" in text
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
    assert "storageClassName: longhorn" in text
    assert "retention_period: 14d" in text


def test_ntfy_argocd_app_uses_ntfy_chart():
    text = NTFY_APP.read_text(encoding="utf-8")
    assert "kind: Application" in text
    assert "name: ntfy" in text
    assert "chart: ntfy" in text
    assert "$values/gitops/values/ntfy.yaml" in text
    assert "namespace: monitoring" in text


def test_ntfy_values_configures_persistence():
    text = NTFY_VALUES.read_text(encoding="utf-8")
    assert "binwiederhier/ntfy" in text
    assert "storageClassName: longhorn" in text
    assert "base-url:" in text
    assert "ntfy.__ZONE_NAME__" in text


def test_ntfy_ingressroute_exposes_ui():
    text = NTFY_INGRESSROUTE.read_text(encoding="utf-8")
    assert "kind: IngressRoute" in text
    assert "Host(`ntfy.__ZONE_NAME__`)" in text
    assert "name: ntfy" in text
    assert "port: 80" in text
    assert "webwiredoor" in text


def test_grafana_values_includes_sidecar_and_datasources():
    text = GRAFANA_VALUES.read_text(encoding="utf-8")
    assert "sidecar:" in text
    assert "datasources:" in text
    assert "enabled: true" in text
    assert "additionalDataSources:" in text
    assert "name: Prometheus" in text
    assert "name: Loki" in text
    assert "type: prometheus" in text
    assert "type: loki" in text


def test_homepage_configmap_includes_monitoring_links():
    text = HOMEPAGE_CONFIGMAP.read_text(encoding="utf-8")
    assert "Prometheus:" in text
    assert "https://prometheus.__ZONE_NAME__" in text
    assert "ntfy:" in text
    assert "https://ntfy.__ZONE_NAME__" in text
    assert "services.yaml" in text
    assert "Metrics collection and alerting" in text
    assert "Push notification service" in text


def test_kustomization_includes_monitoring_resources():
    text = KUSTOMIZATION.read_text(encoding="utf-8")
    assert "prometheus/ingressroute.yaml" in text
    assert "prometheus/alertmanager-config.yaml" in text
    assert "ntfy/ingressroute.yaml" in text


def test_databases_kustomization_includes_authentik_resources():
    text = DATABASES_KUSTOMIZATION.read_text(encoding="utf-8")
    assert "namespace.yaml" in text
    assert "longhorn-single-storageclass.yaml" in text
    assert "authentik/cluster.yaml" in text
    assert "authentik/externalsecret.yaml" in text
    assert "authentik/pooler-ro.yaml" in text
    assert "authentik/pooler-rw.yaml" in text
    assert "authentik/scheduled-backup.yaml" in text


def test_authentik_db_cluster_is_scaled_for_lab_capacity():
    text = AUTHENTIK_DB_CLUSTER.read_text(encoding="utf-8")
    assert "instances: 1" in text
    assert "size: 2Gi" in text
    assert "storageClass: longhorn-single" in text


def test_authentik_db_storageclass_uses_single_replica():
    text = AUTHENTIK_DB_STORAGECLASS.read_text(encoding="utf-8")
    assert "name: longhorn-single" in text
    assert 'numberOfReplicas: "1"' in text
    assert "provisioner: driver.longhorn.io" in text


def test_authentik_values_request_memory_for_server_and_worker():
    text = (REPO_ROOT / "gitops" / "values" / "authentik.yaml").read_text(
        encoding="utf-8"
    )
    assert "server:\n  resources:\n    requests:\n      cpu: 100m\n      memory: 512Mi" in text
    assert "limits:\n      memory: 1Gi" in text
    assert "worker:\n  resources:\n    requests:\n      cpu: 100m\n      memory: 256Mi" in text
    assert "limits:\n      memory: 512Mi" in text
    assert "authentik:\n  existingSecret:" in text
