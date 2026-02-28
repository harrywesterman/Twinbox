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
    assert '--tags "twinbox;management;docker;bootstrap"' in text


def test_setup_wizard_collects_cloud_init_settings():
    text = _wizard_text()
    assert 'CLOUD_INIT_USER="twinbox"' in text
    assert 'password_box "Cloud-Init" "Twinbox login password" CLOUD_INIT_PASSWORD' in text
    assert 'input_box "Cloud-Init" "Static IPv4 address' in text
    assert 'input_box "Cloud-Init" "Netmask' in text
    assert 'input_box "Cloud-Init" "Default route (gateway)' in text
    assert 'input_box "Cloud-Init" "DNS search domain' in text
    assert 'input_box "Cloud-Init" "DNS server IP' in text


def test_setup_wizard_applies_cloud_init_user_and_dns_to_vm():
    text = _wizard_text()
    assert "  - name: ${CLOUD_INIT_USER}" in text
    assert "    lock_passwd: false" in text
    assert "    passwd: ${CLOUD_INIT_PASSWORD_HASH}" in text
    assert "ssh_pwauth: true" in text
    assert "    sudo: ['ALL=(ALL) NOPASSWD:ALL']" in text
    assert "  - path: /home/${CLOUD_INIT_USER}/twinbox.env.template" in text
    assert 'qm set "$MGT_ID" --ciuser "$CLOUD_INIT_USER" >/dev/null' in text
    assert 'qm set "$MGT_ID" --cipassword "$CLOUD_INIT_PASSWORD" >/dev/null' in text
    assert 'qm set "$MGT_ID" --searchdomain "$CLOUD_INIT_DNS_DOMAIN" >/dev/null' in text
    assert 'qm set "$MGT_ID" --nameserver "$CLOUD_INIT_DNS_IP" >/dev/null' in text
    assert 'qm set "$MGT_ID" --ipconfig0 "ip=${CLOUD_INIT_IP}/${CLOUD_INIT_CIDR},gw=${CLOUD_INIT_GATEWAY}" >/dev/null' in text


def test_setup_wizard_discovers_management_vm_ip_via_guest_agent():
    text = _wizard_text()
    assert "discover_management_vm_ip()" in text
    assert 'qm guest cmd "$MGT_ID" network-get-interfaces' in text
    assert 'if [[ -n "${management_ip:-}" ]]; then' in text


def test_setup_wizard_prints_resolved_urls_when_ip_is_available():
    text = _wizard_text()
    assert 'echo "2. Open: http://${management_ip}:3000"' in text
    assert 'echo "3. Verify API health: http://${management_ip}:8080/api/health"' in text


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


def test_setup_wizard_includes_more_explanatory_question_text():
    text = _wizard_text()
    assert "name shown in Proxmox UI" in text
    assert "bridge used for VM network interface" in text
    assert "search domain used in /etc/resolv.conf" in text
    assert "used by worker to call Proxmox API" in text


def test_setup_wizard_finds_first_free_vmid_cluster_wide():
    text = _wizard_text()
    assert 'pvesh get /cluster/resources --type vm --output-format json' in text
    assert "used_vmids=$(printf '%s\\n' \"$cluster_vms\"" in text
    assert 'while printf \'%s\\n\' "$used_vmids" | grep -qx "$candidate"; do' in text


def test_setup_wizard_generates_proxmox_api_password_without_prompting():
    text = _wizard_text()
    assert "PROXMOX_PASSWORD=$(generate_cloud_init_password)" in text
    assert 'password_box "Manager .env" "Proxmox API password' not in text
    assert 'if [[ -z "${PROXMOX_PASSWORD:-}" ]]; then' not in text
    assert 'PROXMOX_USER="twinbox@pve"' in text


def test_setup_wizard_prints_proxmox_api_credentials():
    text = _wizard_text()
    assert 'echo "Proxmox API user: ${PROXMOX_USER}"' in text
    assert 'echo "Proxmox API password: ${PROXMOX_PASSWORD}"' in text


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


def test_setup_wizard_requires_non_empty_ssh_key():
    text = _wizard_text()
    assert 'if [[ -z "${SSH_KEY:-}" ]]; then' in text
    assert 'if [[ -z "${SSH_KEY// }" ]]; then' in text
    assert 'msg_error "SSH public key is required for initial access"' in text


def test_setup_wizard_creates_dedicated_limited_proxmox_api_user():
    text = _wizard_text()
    assert "create_proxmox_api_user()" in text
    assert 'proxmox_user_exists()' in text
    assert 'if proxmox_user_exists "$PROXMOX_USER"; then' in text
    assert 'if ! wait_for_proxmox_user "$PROXMOX_USER" 15 1; then' in text
    assert 'status_update "Proxmox API user ${PROXMOX_USER} not yet visible in list; continuing"' in text
    assert 'create_err=$(pveum user add "$PROXMOX_USER" --comment "Twinbox service account" 2>&1)' in text
    assert 'msg_error "Failed to create Proxmox API user ${PROXMOX_USER}: ${create_err}"' in text
    assert 'set_proxmox_password_with_retry()' in text
    assert 'if ! set_proxmox_password_with_retry "$PROXMOX_USER" "$PROXMOX_PASSWORD" 15 1; then' in text
    assert 'msg_error "Failed to set password for Proxmox API user ${PROXMOX_USER}"' in text
    assert 'pveum passwd "$user"' in text
    assert 'pveum role add "$PROXMOX_ROLE"' in text
    assert 'VM.Allocate,VM.Config.CPU,VM.Config.Disk,VM.Config.Memory,VM.Config.Network,VM.Config.Options,VM.PowerMgmt,Datastore.AllocateSpace,Datastore.Audit' in text
    assert 'pveum aclmod /vms -user "$PROXMOX_USER" -role "$PROXMOX_ROLE"' in text
    assert 'pveum aclmod /storage -user "$PROXMOX_USER" -role "$PROXMOX_ROLE"' in text
    assert 'pveum aclmod "/nodes/${PROXMOX_NODE}" -user "$PROXMOX_USER" -role "$PROXMOX_ROLE"' in text
