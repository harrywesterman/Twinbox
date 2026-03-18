from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
WIZARD_PATH = REPO_ROOT / "wizard" / "setup-wizard.sh"


def _wizard_text() -> str:
    return WIZARD_PATH.read_text(encoding="utf-8")


def test_setup_wizard_registers_exit_cleanup_trap():
    text = _wizard_text()
    assert "trap cleanup_after_run EXIT" in text


def test_setup_wizard_cleanup_removes_snippet_on_error():
    text = _wizard_text()
    assert '[[ -n "${snippet_file:-}" && -f "$snippet_file" ]]' in text
    assert 'rm -f "$snippet_file"' in text


def test_setup_wizard_cleanup_rolls_back_created_vm_on_error():
    text = _wizard_text()
    assert '[[ "${vm_created:-0}" -eq 1 ]]' in text
    assert 'qm stop "$MGT_ID" --skiplock 1 >/dev/null 2>&1 || true' in text
    assert 'qm destroy "$MGT_ID" --purge 1 >/dev/null 2>&1 || true' in text


def test_setup_wizard_enables_guest_agent_on_management_vm():
    text = _wizard_text()
    assert "  - qemu-guest-agent" in text
    assert "  - systemctl enable --now qemu-guest-agent" in text
    assert 'qm set "$MGT_ID" --agent enabled=1 >/dev/null' in text
    assert '--tags "twinbox;management;docker;bootstrap;${CLUSTER_VM_TAG}"' in text


def test_setup_wizard_collects_cloud_init_settings():
    text = _wizard_text()
    assert 'CLOUD_INIT_USER="twinbox-${CLUSTER_SLUG}"' in text
    assert 'password_box "Cloud-Init" "Twinbox login password" CLOUD_INIT_PASSWORD' in text
    assert 'input_box "Cloud-Init" "SSH public key (used for initial SSH access)" "$SSH_KEY" SSH_KEY' in text
    assert 'The allocation grid fills the management VM network fields.' in text


def test_setup_wizard_applies_cloud_init_user_and_dns_to_vm():
    text = _wizard_text()
    assert "  - name: ${CLOUD_INIT_USER}" in text
    assert "    lock_passwd: false" in text
    assert "    passwd: ${CLOUD_INIT_PASSWORD_HASH}" in text
    assert "ssh_pwauth: true" in text
    assert "    sudo: ['ALL=(ALL) NOPASSWD:ALL']" in text
    assert "  - path: /tmp/twinbox-${CLUSTER_SLUG}.env.template" in text
    assert "    owner: root:root" in text
    assert "      TWINBOX_CLUSTER_SLUG=${CLUSTER_SLUG}" in text
    assert "      TALOSCTL_VERSION=${TALOSCTL_VERSION}" in text
    assert "      KUBECTL_VERSION=${KUBECTL_VERSION}" in text
    assert "      HELM_VERSION=${HELM_VERSION}" in text
    assert "  - install -m 0600 -o ${CLOUD_INIT_USER} -g ${CLOUD_INIT_USER} /tmp/twinbox-${CLUSTER_SLUG}.env.template ${TWINBOX_TARGET_DIR}/.env" in text
    assert "  - bash -lc 'cd ${TWINBOX_TARGET_DIR} && chmod +x scripts/install-management-tools.sh && ./scripts/install-management-tools.sh --env-file ${TWINBOX_TARGET_DIR}/.env'" in text
    assert 'qm set "$MGT_ID" --ciuser "$CLOUD_INIT_USER" >/dev/null' in text
    assert 'qm set "$MGT_ID" --cipassword "$CLOUD_INIT_PASSWORD" >/dev/null' in text
    assert 'qm set "$MGT_ID" --searchdomain "$CLOUD_INIT_DNS_DOMAIN" >/dev/null' in text
    assert 'qm set "$MGT_ID" --nameserver "$CLOUD_INIT_DNS_IP" >/dev/null' in text
    assert 'qm set "$MGT_ID" --ipconfig0 "ip=${CLOUD_INIT_IP}/${CLOUD_INIT_CIDR},gw=${CLOUD_INIT_GATEWAY}" >/dev/null' in text
    assert "CLUSTER_NAME=${CLUSTER_NAME}" in text
    assert "CLUSTER_CONTROLPLANE_COUNT=${CLUSTER_CONTROLPLANE_COUNT}" in text
    assert "CLUSTER_WORKER_COUNT=${CLUSTER_WORKER_COUNT}" in text
    assert "MANAGEMENT_VM_ID=${MGT_ID}" in text
    assert "MANAGEMENT_VM_IP=${CLOUD_INIT_IP}" in text
    assert "VIP_IP=${VIP_IP}" in text
    assert "CLUSTER_START_VMID=${CLUSTER_START_VMID}" in text
    assert "CLUSTER_START_IP=${CLUSTER_START_IP}" in text


def test_setup_wizard_discovers_management_vm_ip_via_guest_agent():
    text = _wizard_text()
    assert "discover_management_vm_ip()" in text
    assert 'qm guest cmd "$MGT_ID" network-get-interfaces' in text
    assert 'if [[ -n "${management_ip:-}" ]]; then' in text


def test_setup_wizard_prints_resolved_urls_when_ip_is_available():
    text = _wizard_text()
    assert 'echo "Open a web browser now: http://${management_ip}:3000"' in text
    assert 'echo "When it is ready, open: http://${management_ip}:3000"' in text


def test_setup_wizard_prints_generated_twinbox_credentials():
    text = _wizard_text()
    assert 'echo "Login user: ${CLOUD_INIT_USER}"' in text
    assert 'echo "Login password: ${CLOUD_INIT_PASSWORD}"' in text


def test_setup_wizard_has_auto_config_path():
    text = _wizard_text()
    assert "apply_educated_defaults()" in text
    assert 'if whiptail --yesno "Use recommended settings with educated guesses?"' in text
    assert "collect_manual_overrides" in text


def test_setup_wizard_uses_detected_ssh_key_when_available():
    text = _wizard_text()
    assert "guess_ssh_public_key()" in text
    assert 'if [[ -z "${SSH_KEY:-}" ]]; then' in text
    assert 'input_box "Cloud-Init" "SSH public key" "" SSH_KEY' in text


def test_setup_wizard_groups_manual_questions_with_review_screens():
    text = _wizard_text()
    assert "review_management_settings()" in text
    assert "review_cloud_init_settings()" in text
    assert "review_manager_env_settings()" in text
    assert 'if whiptail --yesno "Management VM settings' in text
    assert 'if whiptail --yesno "Cloud-Init settings' in text
    assert 'if whiptail --yesno "Manager API settings' in text
    assert 'The allocation grid sets VMID, IP and future cluster ranges.' in text
    assert 'The allocation grid fills the management VM network fields.' in text


def test_setup_wizard_includes_more_explanatory_question_text():
    text = _wizard_text()
    assert "name shown in Proxmox UI" in text
    assert "bridge used for VM network interface" in text
    assert "used by worker to call Proxmox API" in text
    assert "Management VM CPU type (use host or x86-64-v2-AES for latest talosctl)" in text
    assert "Talosctl version (tooling on management host and worker)" in text
    assert "kubectl version (tooling on management host and worker)" in text
    assert "Helm version (tooling on management host and worker)" in text
    assert "The allocation grid sets VMID, IP and future cluster ranges." in text
    assert "The allocation grid sets VMID, IP and future cluster ranges." in text


def test_setup_wizard_finds_first_free_vmid_cluster_wide():
    text = _wizard_text()
    assert 'pvesh get /cluster/resources --type vm --output-format json' in text
    assert "used_vmids=$(printf '%s\\n' \"$cluster_vms\"" in text
    assert "guess_free_vmid_block()" in text
    assert "guess_free_ip_block()" in text
    assert 'guess_free_ip_block "${detected_host:-}" "$total_ips"' in text


def test_setup_wizard_auto_selects_management_ip_using_ping_probe():
    text = _wizard_text()
    assert "guess_free_management_ip()" in text
    assert 'if ping -c 1 -W 1 "$candidate" >/dev/null 2>&1; then' in text
    assert 'guess_free_ip_block()' in text
    assert 'CLOUD_INIT_IP="${cluster_block_ip:-192.168.1.50}"' in text


def test_setup_wizard_generates_proxmox_api_password_without_prompting():
    text = _wizard_text()
    assert "PROXMOX_PASSWORD=$(generate_cloud_init_password)" in text
    assert 'password_box "Manager .env" "Proxmox API password' not in text
    assert 'if [[ -z "${PROXMOX_PASSWORD:-}" ]]; then' not in text
    assert 'PROXMOX_USER="twinbox-${CLUSTER_SLUG}@pve"' in text


def test_setup_wizard_prints_proxmox_api_credentials():
    text = _wizard_text()
    assert 'echo "Proxmox API user: ${PROXMOX_USER}"' in text
    assert 'echo "Proxmox API password: ${PROXMOX_PASSWORD}"' in text
    assert 'echo "Cluster VIP: ${VIP_IP}"' in text
    assert 'echo "Cluster start VMID: ${CLUSTER_START_VMID}"' in text
    assert 'echo "Cluster start IP: ${CLUSTER_START_IP}"' in text


def test_setup_wizard_builds_editable_cluster_allocation_grid():
    text = _wizard_text()
    assert "whiptail_supports_form()" in text
    assert "edit_cluster_allocation_table_fallback()" in text
    assert "build_cluster_allocation_rows()" in text
    assert "render_cluster_allocation_table()" in text
    assert "edit_cluster_allocation_table()" in text
    assert 'if whiptail_supports_form; then' in text
    assert 'collect_cluster_allocation "${MGT_ID}" "${CLOUD_INIT_IP}" "${CLOUD_INIT_NETMASK}" "${CLOUD_INIT_GATEWAY}" "${CLOUD_INIT_DNS_IP}" "${CLUSTER_CONTROLPLANE_COUNT}" "${CLUSTER_WORKER_COUNT}" cluster_vmids cluster_names cluster_ips cluster_subnets cluster_gateways cluster_dns cluster_roles' in text
    assert 'msg_box "Cluster Allocation" "Review the proposed allocation grid.' in text
    assert 'input_box "Cluster Allocation" "Row ${i} (${_rows_roles[$i]})\\nEnter values as: vmid|name|ip|subnet|gateway|dns"' in text


def test_setup_wizard_avoids_circular_nameref_calls_in_allocation_helpers():
    text = _wizard_text()
    assert 'build_cluster_allocation_rows _rows_roles _rows_vmids _rows_names _rows_ips _rows_subnets _rows_gateways _rows_dns' not in text
    assert 'edit_cluster_allocation_table "Cluster Allocation" _rows_roles _rows_vmids _rows_names _rows_ips _rows_subnets _rows_gateways _rows_dns' not in text


def test_setup_wizard_uses_host_cpu_type_by_default():
    text = _wizard_text()
    assert 'MGT_CPU_TYPE="host"' in text
    assert '--cpu "$MGT_CPU_TYPE"' in text


def test_setup_wizard_converts_netmask_to_cidr():
    text = _wizard_text()
    assert "netmask_to_cidr()" in text
    assert 'for octet in "${octets[@]}"; do' in text
    assert 'CLOUD_INIT_CIDR=$(netmask_to_cidr "$CLOUD_INIT_NETMASK")' in text
    assert "local seen_partial_or_zero=0" in text
    assert 'if [[ "$octet" -eq 255 ]]; then' in text
    assert 'if [[ "$seen_partial_or_zero" -eq 1 ]]; then' in text


def test_setup_wizard_shows_runtime_progress_feedback():
    text = _wizard_text()
    assert "status_update()" in text
    assert 'status_update "Preparing cloud-init configuration snippet"' in text
    assert 'status_update "Creating VM shell in Proxmox"' in text
    assert 'status_update "Importing base disk into VM storage"' in text
    assert 'status_update "Starting management VM"' in text
    assert 'status_update "Waiting for guest agent to report management VM IP"' in text
    assert 'status_update() { echo -e " ${HOLD} ${YW}[$(date \'+%H:%M:%S\')] $1${CL}" >&2; }' in text


def test_setup_wizard_downloads_talos_iso_when_missing():
    text = _wizard_text()
    assert "ensure_talos_iso_available()" in text
    assert 'status_update "Checking Talos ISO in storage ${PROXMOX_ISO_STORAGE}"' in text
    assert 'pvesm list "$PROXMOX_ISO_STORAGE" --content iso' in text
    assert 'pvesm download "$PROXMOX_ISO_STORAGE" "$TALOS_ISO_FILE" "$talos_url"' in text
    assert 'msg_ok "Talos ISO downloaded (${TALOS_ISO_FILE})"' in text


def test_setup_wizard_requires_non_empty_ssh_key():
    text = _wizard_text()
    assert 'if [[ -z "${SSH_KEY:-}" ]]; then' in text
    assert 'if [[ -z "${SSH_KEY// }" ]]; then' in text
    assert 'msg_error "SSH public key is required for initial access"' in text


def test_setup_wizard_creates_dedicated_limited_proxmox_api_user():
    text = _wizard_text()
    assert "create_proxmox_api_user()" in text
    assert 'create_err=$(pveum user add "$PROXMOX_USER" --comment "Twinbox service account (${CLUSTER_SLUG})" 2>&1)' in text
    assert 'if printf \'%s\' "$create_err" | grep -qi "already exists"; then' in text
    assert 'msg_error "Failed to create Proxmox API user ${PROXMOX_USER}: ${create_err}"' in text
    assert 'set_proxmox_password_with_retry()' in text
    assert 'if ! set_proxmox_password_with_retry "$PROXMOX_USER" "$PROXMOX_PASSWORD" 15 1; then' in text
    assert 'msg_error "Failed to set password for Proxmox API user ${PROXMOX_USER}: ${last_err}"' in text
    assert 'pveum passwd "$user"' in text
    assert 'role_err=$(pveum role add "$PROXMOX_ROLE" -privs "$proxmox_privs" 2>&1)' in text
    assert 'if printf \'%s\' "$role_err" | grep -qi "already exists"; then' in text
    assert 'role_err=$(pveum role modify "$PROXMOX_ROLE" -privs "$proxmox_privs" 2>&1)' in text
    assert 'apply_acl_with_retry()' in text
    assert 'pveum role add "$PROXMOX_ROLE"' in text
    assert 'VM.Allocate,VM.Config.CPU,VM.Config.Disk,VM.Config.Memory,VM.Config.Network,VM.Config.Options,VM.Config.HWType,VM.PowerMgmt,Datastore.AllocateSpace,Datastore.Audit,SDN.Use' in text
    assert 'for acl_path in /vms /storage "/nodes/${PROXMOX_NODE}"; do' in text
    assert 'pveum aclmod "$path" -user "$user" -role "$role" 2>&1' in text
    assert 'if ! apply_acl_with_retry "/sdn" "$PROXMOX_USER" "$PROXMOX_ROLE" 10 1; then' in text


def test_setup_wizard_supports_cluster_slug_selection_and_normalization():
    text = _wizard_text()
    assert "sanitize_cluster_slug()" in text
    assert "choose_cluster_slug()" in text
    assert '"ontwikkel" "Development cluster"' in text
    assert '"test" "Testing cluster"' in text
    assert '"productie" "Production cluster"' in text
    assert '"aangepast" "Custom cluster name"' in text
    assert "set_cluster_naming_defaults()" in text
    assert 'MGT_NAME="${CLUSTER_VM_PREFIX}mgt"' in text
    assert 'PROXMOX_ROLE="TwinboxVMProvisioner-${CLUSTER_SLUG}"' in text


def test_setup_wizard_detects_and_cleans_up_existing_cluster_resources():
    text = _wizard_text()
    assert "detect_existing_cluster_resources()" in text
    assert "cluster_resources_exist()" in text
    assert "render_existing_cluster_inventory()" in text
    assert "cleanup_existing_cluster_resources()" in text
    assert "handle_existing_cluster_conflict()" in text
    assert 'if [[ "$tags" =~ (^|;)${CLUSTER_VM_TAG}($|;) ]]; then' in text
    assert 'pveum aclmod "$acl_path" -user "$PROXMOX_USER" -delete 1 >/dev/null 2>&1 || true' in text
    assert 'pveum user delete "$PROXMOX_USER" >/dev/null 2>&1 || true' in text
    assert 'pveum role delete "$PROXMOX_ROLE" >/dev/null 2>&1 || true' in text
    assert "Type the cluster slug to confirm deletion" in text
    assert "Do you want to recreate it now?" in text
