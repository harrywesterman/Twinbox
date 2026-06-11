from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
WIZARD_PATH = REPO_ROOT / "wizard" / "setup-wizard.sh"


def _wizard_text() -> str:
    return WIZARD_PATH.read_text(encoding="utf-8")


def test_setup_wizard_registers_exit_cleanup_trap():
    text = _wizard_text()
    assert "trap cleanup_after_run EXIT" in text


def test_setup_wizard_cleanup_removes_completion_state_file():
    text = _wizard_text()
    assert '[[ -n "${completion_state_file:-}" && -f "$completion_state_file" ]]' in text
    assert 'rm -f "$completion_state_file"' in text


def test_setup_wizard_cleanup_removes_snippet_on_error():
    text = _wizard_text()
    assert '[[ -n "${snippet_file:-}" && -f "$snippet_file" ]]' in text
    assert 'rm -f "$snippet_file"' in text


def test_setup_wizard_cleanup_rolls_back_created_vm_on_error():
    text = _wizard_text()
    assert '[[ "${vm_created:-0}" -eq 1 ]]' in text
    assert 'qm stop "$MGT_ID" --skiplock 1 >/dev/null 2>&1 || true' in text
    assert 'qm destroy "$MGT_ID" --purge 1 >/dev/null 2>&1 || true' in text


def test_setup_wizard_cleanup_uses_cluster_inventory_for_detect_and_remove():
    text = _wizard_text()
    assert "EXISTING_VM_NODES=()" in text
    assert "EXISTING_VM_TAGS=()" in text
    assert "cluster_vm_inventory()" in text
    assert "pvesh get /cluster/resources --type vm --output-format json" in text
    assert "proxmox_user_exists()" in text
    assert "proxmox_role_exists()" in text
    assert "pvesh get /access/users --output-format json" in text
    assert "pvesh get /access/roles --output-format json" in text
    assert "python3 -c" in text
    assert 'rows = payload.get("data", payload) if isinstance(payload, dict) else payload' in text
    assert 'name.startswith(cluster_prefix) or cluster_tag in tags.split(";")' in text
    assert "declare -A seen_vm_names=()" in text
    assert "declare -A seen_vmids=()" in text
    assert "WARNING: cluster VM ${name} appears on multiple Proxmox nodes" in text
    assert "WARNING: VMID ${vmid} appears on multiple Proxmox nodes" in text
    assert 'EXISTING_VM_NODES+=("$node")' in text
    assert 'EXISTING_VM_TAGS+=("$tags")' in text
    assert "This will remove:" in text
    assert "- VMs: ${#EXISTING_VM_IDS[@]}" in text
    assert "- Snippet files: ${#EXISTING_SNIPPETS[@]}" in text
    assert "- Proxmox API user: " in text
    assert "- Proxmox API role: " in text
    assert "present" in text
    assert "not found" in text
    assert "VM inventory:" in text
    assert "(VMID ${EXISTING_VM_IDS[$idx]} on ${EXISTING_VM_NODES[$idx]})" in text
    assert "Remove these resources now?" in text
    assert "Remove these resources before starting again?" in text
    assert "This cannot be undone." in text
    assert "Destroying VM ${vmid} (${vm_name}) on ${vm_node}" in text
    assert "VM ${vm_name} tags: ${vm_tags}" in text
    assert 'pvesh create "/nodes/${vm_node}/qemu/${vmid}/status/stop"' in text
    assert 'pvesh delete "/nodes/${vm_node}/qemu/${vmid}" --purge 1' in text
    assert "Removed Proxmox API user ${PROXMOX_USER}" in text
    assert "Removed Proxmox role ${PROXMOX_ROLE}" in text
    assert "Removed ${#EXISTING_SNIPPETS[@]} snippet(s)" in text


def test_setup_wizard_enables_guest_agent_on_management_vm():
    text = _wizard_text()
    assert "  - qemu-guest-agent" in text
    assert (
        "ansible-playbook -i localhost, -c local /opt/twinbox/bootstrap/ansible/management-vm-maintenance.yml"
        in text
    )
    assert 'qm set "$MGT_ID" --agent enabled=1 >/dev/null' in text
    assert '--tags "twinbox;management;docker;bootstrap;${CLUSTER_VM_TAG}"' in text


def test_setup_wizard_collects_cloud_init_settings():
    text = _wizard_text()
    assert 'CLOUD_INIT_USER="twinbox"' in text
    assert 'password_box_confirm "Twinbox" "Cluster login password" CLOUD_INIT_PASSWORD' in text
    assert 'input_box "Twinbox" "SSH public key" "$SSH_KEY" SSH_KEY' in text


def test_setup_wizard_applies_cloud_init_user_and_dns_to_vm():
    text = _wizard_text()
    assert "  - name: ${CLOUD_INIT_USER}" in text
    assert "    lock_passwd: false" in text
    assert '      password: "${CLOUD_INIT_PASSWORD}"' in text
    assert "      type: text" in text
    assert "ssh_pwauth: true" in text
    assert "    sudo: ['ALL=(ALL) NOPASSWD:ALL']" in text
    assert "  - path: /tmp/twinbox.env.template" in text
    assert "    owner: root:root" in text
    assert "      TWINBOX_CLUSTER_SLUG=${CLUSTER_SLUG}" in text
    assert "      TWINBOX_HOST_REPO_ROOT=${TWINBOX_TARGET_DIR}" in text
    assert 'TWINBOX_TARGET_DIR="/opt/twinbox"' in text
    assert "      TWINBOX_SECRET_BACKEND=filesystem" in text
    assert "      TWINBOX_BOOTSTRAP_DIR=/opt/twinbox/bootstrap" in text
    assert "      TWINBOX_SECRET_ITEM_PREFIX=twinbox" in text
    assert "      TWINBOX_SECRET_TEMP_DIR=/tmp/twinbox-secrets" in text
    assert "      TWINBOX_SECRET_CACHE_TTL_SEC=60" in text
    assert "      TALOS_IMAGE_SCHEMATIC=${TALOS_IMAGE_SCHEMATIC}" not in text
    assert "      TALOSCTL_VERSION=${TALOSCTL_VERSION}" not in text
    assert "      PROXMOX_ISO_STORAGE=${PROXMOX_ISO_STORAGE}" not in text
    assert "      TALOS_ISO_FILE=${TALOS_ISO_FILE}" not in text
    assert "  - install -m 0755 -d /opt/twinbox/bootstrap/ansible" in text
    assert "  - install -m 0755 -d /opt/twinbox/manager-data" in text
    assert "  - install -m 0755 -d /opt/twinbox/seaweedfs/data" in text
    assert (
        "  - install -m 0600 -o ${CLOUD_INIT_USER} -g ${CLOUD_INIT_USER} /tmp/twinbox.env.template ${TWINBOX_TARGET_DIR}/.env"
        in text
    )
    assert 'qm set "$MGT_ID" --ciuser "$CLOUD_INIT_USER" >/dev/null' in text
    assert 'qm set "$MGT_ID" --cipassword "$CLOUD_INIT_PASSWORD" >/dev/null' in text
    assert 'qm set "$MGT_ID" --searchdomain "$CLOUD_INIT_DNS_DOMAIN" >/dev/null' in text
    assert 'qm set "$MGT_ID" --nameserver "$CLOUD_INIT_DNS_IP" >/dev/null' in text
    assert (
        'qm set "$MGT_ID" --ipconfig0 "ip=${CLOUD_INIT_IP}/${CLOUD_INIT_CIDR},gw=${CLOUD_INIT_GATEWAY}" >/dev/null'
        in text
    )
    assert "MANAGEMENT_VM_ID=${MGT_ID}" in text
    assert "MANAGEMENT_VM_IP=${CLOUD_INIT_IP}" in text
    assert (
        "bash -lc 'set -a; source ${TWINBOX_TARGET_DIR}/.env; set +a; cd ${TWINBOX_TARGET_DIR} && ansible-playbook -i localhost, -c local /opt/twinbox/bootstrap/ansible/management-vm-maintenance.yml'"
        in text
    )
    assert "CLUSTER_NAME=${CLUSTER_NAME}" not in text
    assert "CLUSTER_CONTROLPLANE_COUNT=${CLUSTER_CONTROLPLANE_COUNT}" not in text
    assert "CLUSTER_WORKER_COUNT=${CLUSTER_WORKER_COUNT}" not in text
    assert "VIP_IP=${VIP_IP}" not in text
    assert "CLUSTER_START_VMID=${CLUSTER_START_VMID}" not in text
    assert "CLUSTER_START_IP=${CLUSTER_START_IP}" not in text
    assert "git clone https://github.com/${GITHUB_REPO}.git ${TWINBOX_TARGET_DIR}" not in text


def test_setup_wizard_bootstraps_filesystem_secret_material_before_starting_manager_stack():
    text = _wizard_text()
    assert "install -m 0755 -d /opt/twinbox/bootstrap/ansible" in text
    assert "install -m 0755 -d /opt/twinbox/bootstrap/config" in text
    assert "install -m 0755 -d /opt/twinbox/bootstrap/bin" in text
    assert "install -m 0755 -d /opt/twinbox/scripts/manager" in text
    assert (
        "bash -lc 'curl -fsSL \"${TWINBOX_RAW_BASE_URL}/scripts/manager/management-ip.sh\" -o /opt/twinbox/scripts/manager/management-ip.sh'"
        in text
    )
    assert "chmod 0755 /opt/twinbox/scripts/manager/management-ip.sh" in text
    assert "MANAGEMENT_VM_IP=${CLOUD_INIT_IP}" in text
    assert "TWINBOX_SECRET_BACKEND=filesystem" in text
    assert "TWINBOX_BOOTSTRAP_DIR=/opt/twinbox/bootstrap" in text
    assert "TWINBOX_SECRET_ITEM_PREFIX=twinbox" in text
    assert "TWINBOX_SECRET_TEMP_DIR=/tmp/twinbox-secrets" in text
    assert "TWINBOX_SECRET_CACHE_TTL_SEC=60" in text
    assert "python3 /tmp/twinbox-write-velero-secret.py" in text
    assert (
        "bash -lc 'set -a; source ${TWINBOX_TARGET_DIR}/.env; set +a; cd ${TWINBOX_TARGET_DIR} && ansible-playbook -i localhost, -c local /opt/twinbox/bootstrap/ansible/management-vm-maintenance.yml'"
        in text
    )
    assert "docker compose up -d vaultwarden" not in text
    assert "scripts/bootstrap-vaultwarden.sh" not in text
    assert "vaultwarden-password" not in text


def test_setup_wizard_starts_manager_script_after_bootstrap_directory_exists():
    text = _wizard_text()
    bootstrap_index = text.index("install -m 0755 -d /opt/twinbox/bootstrap/ansible")
    bootstrap_script_index = text.index(
        "ansible-playbook -i localhost, -c local /opt/twinbox/bootstrap/ansible/management-vm-maintenance.yml"
    )

    assert bootstrap_index < bootstrap_script_index


def test_setup_wizard_discovers_management_vm_ip_via_guest_agent():
    text = _wizard_text()
    assert "discover_management_vm_ip()" in text
    assert 'qm guest cmd "$MGT_ID" network-get-interfaces' in text
    assert 'DISCOVERED_MANAGEMENT_IP="$ip"' in text
    assert 'management_ip="${DISCOVERED_MANAGEMENT_IP:-}"' in text
    assert "management_ip=$(discover_management_vm_ip)" not in text
    assert 'wait_for_web_interface "$management_ip"' in text


def test_setup_wizard_does_not_block_website_detection_on_ping():
    text = _wizard_text()
    prepare_body = text.split("prepare_completion_message() {", 1)[1].split(
        "run_installation_flow()", 1
    )[0]
    assert 'wait_for_management_vm_ping "$management_ip"' not in prepare_body
    assert 'wait_for_web_interface "$management_ip"' in prepare_body


def test_setup_wizard_persists_completion_message_across_programbox_install_flow():
    text = _wizard_text()
    flow_body = text.split("run_installation_flow() {", 1)[1].split("print_next_steps()", 1)[0]
    assert flow_body.count("prepare_completion_message") == 1
    assert "set +e" in flow_body
    assert "} 2>&1 | dialog \\" in flow_body
    assert "install_exit=${PIPESTATUS[0]}" in flow_body
    assert 'if [[ "$install_exit" -ne 0 ]]; then' in flow_body
    assert "MANAGEMENT_WEB_URL=$(tr -d '\\r' <\"$completion_state_file\")" in flow_body
    assert 'FINAL_COMPLETION_MESSAGE="Twinbox is ready."' in flow_body


def test_setup_wizard_prints_resolved_urls_when_ip_is_available():
    text = _wizard_text()
    assert "Open the Twinbox web interface:" in text
    assert 'MANAGEMENT_WEB_URL="http://${management_ip}:3000"' in text
    assert 'printf \'%s\\n\' "$MANAGEMENT_WEB_URL" >"$completion_state_file"' in text
    assert 'log_event "Twinbox is ready at ${MANAGEMENT_WEB_URL}"' in text
    assert 'FINAL_COMPLETION_MESSAGE="Twinbox is ready."' in text
    assert "Open the Twinbox web interface:\\n\\n${MANAGEMENT_WEB_URL}" in text


def test_setup_wizard_falls_back_to_cloud_init_ip_when_guest_agent_ip_is_empty():
    text = _wizard_text()
    prepare_body = text.split("prepare_completion_message() {", 1)[1].split(
        "run_installation_flow()", 1
    )[0]
    assert 'management_ip="${management_ip:-$CLOUD_INIT_IP}"' in prepare_body
    assert 'MANAGEMENT_WEB_URL="http://${management_ip}:3000"' in prepare_body


def test_setup_wizard_hides_generated_twinbox_credentials():
    text = _wizard_text()
    assert "Login password: ${CLOUD_INIT_PASSWORD}" not in text
    assert "Proxmox API password: ${PROXMOX_PASSWORD}" not in text


def test_setup_wizard_applies_defaults_without_extra_confirmation():
    text = _wizard_text()
    assert "apply_educated_defaults()" in text
    assert "Use recommended defaults?" not in text


def test_setup_wizard_uses_detected_ssh_key_when_available():
    text = _wizard_text()
    assert "guess_ssh_public_key()" in text
    assert 'if [[ -z "${SSH_KEY:-}" ]]; then' in text
    assert 'input_box "Twinbox" "SSH public key" "$SSH_KEY" SSH_KEY' in text


def test_setup_wizard_asks_manual_questions_without_review_screens():
    text = _wizard_text()
    assert "review_management_settings()" not in text
    assert "review_cloud_init_settings()" not in text
    assert "review_manager_env_settings()" not in text


def test_setup_wizard_keeps_question_text_short():
    text = _wizard_text()
    assert "name shown in Proxmox UI" not in text
    assert "bridge used for VM network interface" not in text
    assert "used by worker to call Proxmox API" not in text
    assert "tooling on management host and worker" not in text


def test_setup_wizard_finds_first_free_vmid_cluster_wide():
    text = _wizard_text()
    assert "pvesh get /cluster/resources --type vm --output-format json" in text
    assert "used_vmids=$(printf '%s\\n' \"$cluster_vms\"" in text
    assert "guess_next_vmid()" in text
    assert "guess_free_vmid_block()" not in text
    assert "guess_free_ip_block()" not in text


def test_setup_wizard_auto_selects_management_ip_using_ping_probe():
    text = _wizard_text()
    assert "guess_free_management_ip()" in text
    assert 'if ping -c 1 -W 1 "$candidate" >/dev/null 2>&1; then' in text
    assert "guess_free_ip_block()" not in text
    assert 'CLOUD_INIT_IP="$(guess_free_management_ip "${detected_host:-}" || true)"' in text


def test_setup_wizard_generates_proxmox_api_password_without_prompting():
    text = _wizard_text()
    assert "PROXMOX_PASSWORD=$(generate_cloud_init_password)" in text
    assert 'password_box "Manager .env" "Proxmox API password' not in text
    assert 'if [[ -z "${PROXMOX_PASSWORD:-}" ]]; then' not in text
    assert 'PROXMOX_USER="twinbox-${CLUSTER_SLUG}@pve"' in text


def test_setup_wizard_does_not_print_proxmox_api_credentials():
    text = _wizard_text()
    assert "Proxmox API user: ${PROXMOX_USER}" not in text
    assert "Proxmox API password: ${PROXMOX_PASSWORD}" not in text


def test_setup_wizard_grants_cloudinit_and_template_datastore_privileges():
    text = _wizard_text()
    assert (
        "VM.Audit,VM.Monitor,VM.Allocate,VM.Config.CPU,VM.Config.Disk,VM.Config.Memory,VM.Config.Network,VM.Config.Options,VM.Config.HWType,VM.Config.Cloudinit,VM.PowerMgmt,Datastore.Allocate,Datastore.AllocateSpace,Datastore.AllocateTemplate,Datastore.Audit,SDN.Use"
        in text
    )


def test_setup_wizard_collects_single_management_vm_form():
    text = _wizard_text()
    assert "build_cluster_allocation_rows()" not in text
    assert "edit_cluster_allocation_table()" not in text
    assert "collect_cluster_allocation()" not in text
    assert '--form "Adjust the settings for the management VM:"' in text
    assert '"Name:"           1 1 "$MGT_NAME"           1 20 30 0' in text
    assert '"IP Address:"     2 1 "$CLOUD_INIT_IP"      2 20 30 0' in text
    assert '"Netmask:"        3 1 "$CLOUD_INIT_NETMASK" 3 20 30 0' in text
    assert '"DNS Server:"     4 1 "$CLOUD_INIT_DNS_IP"  4 20 30 0' in text
    assert '"Disk Size (GB):" 5 1 "$MGT_DISK"           5 20 10 0' in text
    assert '"Memory (MB):"    6 1 "$MGT_RAM"            6 20 10 0' in text


def test_setup_wizard_no_longer_generates_vip_or_talos_vm_names():
    text = _wizard_text()
    assert '_rows_names+=("twinbox-${CLUSTER_SLUG}-vip")' not in text
    assert 'role="twinbox-${CLUSTER_SLUG}-cp-${index}"' not in text
    assert 'role="twinbox-${CLUSTER_SLUG}-worker-${index}"' not in text


def test_setup_wizard_avoids_circular_nameref_calls_in_allocation_helpers():
    text = _wizard_text()
    assert (
        "build_cluster_allocation_rows _rows_roles _rows_vmids _rows_names _rows_ips _rows_subnets _rows_gateways _rows_dns"
        not in text
    )
    assert (
        'edit_cluster_allocation_table "Cluster Allocation" _rows_roles _rows_vmids _rows_names _rows_ips _rows_subnets _rows_gateways _rows_dns'
        not in text
    )


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
    assert "LIVE_LOG_MODE=0" in text
    assert "run_installation_flow()" in text
    assert "render_installation_banner()" in text
    assert '--title "Twinbox Setup"' in text
    assert '--programbox "Management VM bootstrap in progress." 24 86' in text
    assert 'whiptail --backtitle "$BACKTITLE" --title "Twinbox" --infobox' not in text
    assert 'while kill -0 "$install_pid" 2>/dev/null; do' not in text
    assert "progress_update()" in text
    assert "run_apply_educated_defaults_with_gauge()" in text
    assert '--gauge "Checking network and free addresses"' in text
    assert 'progress_update "Preparing" "Checking network and free addresses"' in text
    assert 'progress_update "Preparing" "Preparing the management VM"' in text
    assert 'progress_update "Starting VM" "Management VM is running"' in text
    assert (
        'progress_update "Waiting for IP" "Waiting for the management VM to receive an IP address"'
        in text
    )
    assert "Twinbox setup" in text
    assert "Management VM bootstrap in progress." in text
    assert "- Creating the management VM" in text
    assert "- Waiting for an IP address" in text
    assert "- Waiting for Twinbox to finish starting" in text
    assert "wait_for_management_vm_ping()" in text
    assert 'log_event "The management VM is responding on the network."' in text
    assert 'log_event "Twinbox is starting in the management VM."' in text
    assert 'log_event "Twinbox is still starting. Usually ready in 2-5 minutes."' in text
    assert 'log_event "Still starting. Usually another 1-3 minutes."' in text
    assert 'log_event "Still starting. Downloads may take a few more minutes."' in text
    assert 'log_event "Still starting. This host is taking longer than usual."' in text
    assert "Web interface still starting (retry ${polls}/72)" not in text
    assert "Web interface did not become reachable within timeout" not in text
    assert "Guest agent did not report an IP within timeout" not in text
    assert "Management VM did not respond to ping within timeout" not in text
    assert 'log_event "The management VM is still requesting an IP address."' in text
    assert 'log_event "The management VM is still booting."' in text
    assert 'log_event "The operating system is still starting."' in text
    assert "This usually settles shortly." not in text
    assert (
        "Cloud-init is still finishing and Docker images may still be downloading. Estimated time remaining: ${eta_text}"
        not in text
    )
    assert "Twinbox services are still starting. Estimated time remaining: ${eta_text}" not in text
    assert (
        "Twinbox is still working in the background. Startup is taking longer than usual, but the wizard is still waiting."
        not in text
    )


def test_setup_wizard_uses_more_lenient_http_readiness_check():
    text = _wizard_text()
    assert (
        'curl --silent --head --output /dev/null --write-out "%{http_code}" --connect-timeout 2 --max-time 10 "$web_url"'
        in text
    )
    assert 'if [[ "${http_code}" != "000" ]]; then' in text
    assert (
        'curl --silent --output /dev/null --connect-timeout 2 --max-time 3 "$web_url"' not in text
    )


def test_setup_wizard_waits_for_real_management_url_without_placeholder_fallback():
    text = _wizard_text()
    assert 'FINAL_COMPLETION_MESSAGE="Twinbox URL: http://<management-vm-ip>:3000"' not in text
    assert (
        'local message="${FINAL_COMPLETION_MESSAGE:-Twinbox URL: http://<management-vm-ip>:3000}"'
        not in text
    )
    assert 'msg_box "Twinbox Setup Complete"' in text


def test_setup_wizard_does_not_manage_talos_install_media():
    text = _wizard_text()
    assert "ensure_talos_iso_available()" not in text
    assert 'progress_update "Preparing cluster" "Checking installation media"' not in text
    assert 'pvesm list "$PROXMOX_ISO_STORAGE" --content iso' not in text
    assert 'pvesm download "$PROXMOX_ISO_STORAGE" "$TALOS_ISO_FILE" "$talos_url"' not in text


def test_setup_wizard_requires_non_empty_ssh_key():
    text = _wizard_text()
    assert 'if [[ -z "${SSH_KEY:-}" ]]; then' in text
    assert 'if [[ -z "${SSH_KEY// }" ]]; then' in text
    assert 'msg_error "SSH public key is required for initial access"' in text


def test_setup_wizard_creates_dedicated_limited_proxmox_api_user():
    text = _wizard_text()
    assert "create_proxmox_api_user()" in text
    assert (
        'create_err=$(pveum user add "$PROXMOX_USER" --comment "Twinbox service account (${CLUSTER_SLUG})" 2>&1)'
        in text
    )
    assert 'if printf \'%s\' "$create_err" | grep -qi "already exists"; then' in text
    assert 'msg_error "Failed to create Proxmox API user ${PROXMOX_USER}: ${create_err}"' in text
    assert "set_proxmox_password_with_retry()" in text
    assert (
        'if ! set_proxmox_password_with_retry "$PROXMOX_USER" "$PROXMOX_PASSWORD" 15 1; then'
        in text
    )
    assert (
        'msg_error "Failed to set password for Proxmox API user ${PROXMOX_USER}: ${last_err}"'
        in text
    )
    assert 'pveum passwd "$user"' in text
    assert 'role_err=$(pveum role add "$PROXMOX_ROLE" -privs "$proxmox_privs" 2>&1)' in text
    assert 'if printf \'%s\' "$role_err" | grep -qi "already exists"; then' in text
    assert 'role_err=$(pveum role modify "$PROXMOX_ROLE" -privs "$proxmox_privs" 2>&1)' in text
    assert "apply_acl_with_retry()" in text
    assert 'pveum role add "$PROXMOX_ROLE"' in text
    assert (
        "VM.Audit,VM.Monitor,VM.Allocate,VM.Config.CPU,VM.Config.Disk,VM.Config.Memory,VM.Config.Network,VM.Config.Options,VM.Config.HWType,VM.Config.Cloudinit,VM.PowerMgmt,Datastore.Allocate,Datastore.AllocateSpace,Datastore.AllocateTemplate,Datastore.Audit,SDN.Use,Sys.Audit,Sys.Modify"
        in text
    )
    assert 'pveum aclmod "$path" -user "$user" -role "$role" 2>&1' in text
    assert 'if ! apply_acl_with_retry "/sdn" "$PROXMOX_USER" "$PROXMOX_ROLE" 10 1; then' in text
    assert "ensure_proxmox_import_content_type()" in text
    assert 'pvesh get "/storage/${datastore}" --output-format json' in text
    assert 'pvesm set "$datastore" --content "$next_content"' in text
    assert "Enabling import content on Proxmox storage ${datastore}" in text
    assert "create_proxmox_api_user\n    ensure_proxmox_import_content_type" in text


def test_setup_wizard_supports_cluster_slug_selection_and_normalization():
    text = _wizard_text()
    assert "sanitize_cluster_slug()" in text
    assert "choose_cluster_slug()" in text
    assert "Choose a cluster name. Default: prd." in text
    assert '"prd" "Use Production (prd)"' in text
    assert '"dev" "Use Development (dev)"' in text
    assert '"tst" "Use Test (tst)"' in text
    assert "set_cluster_naming_defaults()" in text
    assert 'MGT_NAME="${CLUSTER_VM_PREFIX}mgt"' in text
    assert 'PROXMOX_ROLE="TwinboxVMProvisioner-${CLUSTER_SLUG}"' in text


def test_setup_wizard_does_not_ask_for_talos_image_preset():
    text = _wizard_text()
    assert "choose_talos_image_preset()" not in text
    assert (
        'whiptail --backtitle "$BACKTITLE" --title "Twinbox" --menu "Choose the Talos image preset."'
        not in text
    )
    assert "TALOS_IMAGE_PRESET" not in text


def test_setup_wizard_detects_and_cleans_up_existing_cluster_resources():
    text = _wizard_text()
    assert "detect_existing_cluster_resources()" in text
    assert "cluster_resources_exist()" in text
    assert "render_existing_cluster_inventory()" in text
    assert "cleanup_existing_cluster_resources()" in text
    assert "cluster_management_menu()" in text
    assert "name.startswith(cluster_prefix)" in text
    assert 'proxmox_user_exists "$PROXMOX_USER"' in text
    assert 'proxmox_role_exists "$PROXMOX_ROLE"' in text
    assert (
        'pveum aclmod "$acl_path" -user "$PROXMOX_USER" -delete 1 >/dev/null 2>&1 || true' in text
    )
    assert 'if pveum user delete "$PROXMOX_USER" >/dev/null 2>&1; then' in text
    assert 'if pveum role delete "$PROXMOX_ROLE" >/dev/null 2>&1; then' in text
    assert "Type the cluster name to remove it" in text


def test_setup_wizard_shows_cluster_overview_before_action():
    text = _wizard_text()
    assert "detect_cluster_slugs()" in text
    assert "render_cluster_overview()" in text
    assert '"create" "[+] Create a new Twinbox Cluster"' in text


def test_setup_wizard_requires_password_confirmation():
    text = _wizard_text()
    assert "password_box_confirm()" in text
    assert "Confirm cluster login password" in text
    assert "Passwords do not match." in text


def test_setup_wizard_uses_kickstart_positioning_and_minimal_handoff():
    text = _wizard_text()
    assert "Twinbox Management" in text
    assert "Open the Twinbox web interface:" in text
    assert "Press OK to return to the main menu." in text
    assert "Security Notice" not in text


def test_setup_wizard_avoids_extra_confirmation_screens_in_create_flow():
    text = _wizard_text()
    assert "Use recommended defaults?" not in text
    assert "Start cluster ${CLUSTER_SLUG}?" not in text
    assert 'msg_box "Cluster Allocation" "Review the proposed allocation grid.' not in text


def test_setup_wizard_switches_to_live_install_log_after_password():
    text = _wizard_text()
    assert 'password_box_confirm "Twinbox" "Cluster login password" CLOUD_INIT_PASSWORD' in text
    assert "run_installation_flow" in text
    assert "create_proxmox_api_user" in text
    assert "create_management_vm" in text
    flow_body = text.split("run_installation_flow() {", 1)[1].split("print_next_steps()", 1)[0]
    assert "set +e" in flow_body
    assert "(\n    set -e" not in flow_body


def test_setup_wizard_surfaces_friendly_proxmox_storage_errors():
    text = _wizard_text()
    assert "run_qm_command()" in text
    assert 'run_qm_command "create VM" qm create "$MGT_ID"' in text
    assert (
        "Storage hint: check local-lvm free space or remove leftover disks for VMID ${MGT_ID}."
        in text
    )
    assert (
        "Cloud-init hint: Proxmox could not create the cloud-init volume for VMID ${MGT_ID}."
        in text
    )


def test_setup_wizard_remove_flow_skips_create_defaults_scan_and_shows_progress():
    text = _wizard_text()
    assert "remove_cluster_flow()" in text
    assert (
        "apply_educated_defaults"
        not in text.split("remove_cluster_flow() {", 1)[1].split("start_wizard()", 1)[0]
    )
    assert 'progress_update "Checking cluster" "Checking cluster resources"' in text
    assert 'progress_update "Checking cluster" "Checking cluster access"' in text
