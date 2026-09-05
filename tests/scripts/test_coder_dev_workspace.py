from pathlib import Path

WORKSPACE_ROOT = Path(__file__).resolve().parents[2]
WORKSPACE_IMAGE = WORKSPACE_ROOT / "images" / "twinbox-dev-workspace" / "Dockerfile"
WORKSPACE_TEMPLATE = (
    WORKSPACE_ROOT / "infra" / "coder" / "templates" / "twinbox-development" / "main.tf"
)
WORKSPACE_NAMESPACE = WORKSPACE_ROOT / "gitops" / "workspace-namespaces" / "coder-workspaces"
WORKSPACE_SKILLS = WORKSPACE_ROOT / "images" / "twinbox-dev-workspace" / "skills"
WORKSPACE_STARTUP = (
    WORKSPACE_ROOT / "images" / "twinbox-dev-workspace" / "bin" / "twinbox-dev-startup"
)
WORKSPACE_TB = WORKSPACE_ROOT / "images" / "twinbox-dev-workspace" / "bin" / "tb"
WORKSPACE_SSH_LOGIN = (
    WORKSPACE_ROOT / "images" / "twinbox-dev-workspace" / "bin" / "twinbox-ssh-login"
)
INSTALL_CODER = WORKSPACE_ROOT / "categories" / "apps" / "steps" / "install-coder" / "run.sh"
PUBLISH_WORKFLOW = WORKSPACE_ROOT / ".github" / "workflows" / "docker-publish.yml"
VERIFY_WORKFLOW = WORKSPACE_ROOT / ".github" / "workflows" / "verify.yml"
OPKSSH_SETUP = WORKSPACE_ROOT / "scripts" / "manager" / "setup-opkssh-authentik.sh"
MANAGER_WORKER_DOCKERFILE = WORKSPACE_ROOT / "manager-worker" / "Dockerfile"


def test_dev_workspace_image_contains_browser_agent_tooling():
    text = WORKSPACE_IMAGE.read_text(encoding="utf-8")

    assert "FROM python:3.14-slim-bookworm" in text
    assert "npm install -g @openai/codex opencode-ai playwright" in text
    assert "npx playwright install --with-deps chromium" in text
    assert "https://cli.github.com/packages/githubcli-archive-keyring.gpg" in text
    assert "apt-get install -y --no-install-recommends gh" in text
    assert "code-server_${CODE_SERVER_VERSION}_${TARGETARCH}.deb" in text
    assert "kubectl" in text
    assert "helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" in text
    assert "talosctl-linux-${TARGETARCH}" in text
    assert "tofu_${OPENTOFU_VERSION#v}_linux_${TARGETARCH}.zip" in text
    assert "opkssh-linux-${TARGETARCH}" in text
    assert "USER coder" in text
    assert "COPY bin/tb /usr/local/bin/tb" in text
    assert "COPY bin/twinbox-ssh-login /usr/local/bin/twinbox-ssh-login" in text
    assert "COPY skills /opt/twinbox-agent-skills" in text
    assert "mkdir -p /home/coder/code /opt/twinbox-opkssh" in text
    assert "ln -s /opt/twinbox-agent-skills /home/coder" not in text


def test_dev_workspace_startup_recreates_home_pvc_runtime_links():
    text = WORKSPACE_STARTUP.read_text(encoding="utf-8")

    assert 'skill_source="/opt/twinbox-agent-skills"' in text
    assert "install_agent_skills" in text
    assert "install_opkssh_config" in text
    assert 'install_skill_link "$HOME/.agents/skills"' in text
    assert 'install_skill_link "$HOME/.codex/skills"' in text
    assert 'install_skill_link "$HOME/.config/opencode/skills"' in text
    assert (
        'opkssh_config_source="${TWINBOX_OPKSSH_CONFIG_SOURCE:-/opt/twinbox-opkssh/config.yml}"'
        in text
    )
    assert 'ln -sfn "$opkssh_config_source" "$HOME/.opk/config.yml"' in text
    assert 'git clone "$repo_url" "$repo_dir"' in text
    assert "continue with an empty workspace" not in text


def test_coder_template_exposes_owned_dev_apps_and_rootless_netbird():
    text = WORKSPACE_TEMPLATE.read_text(encoding="utf-8")

    assert 'resource "coder_app" "code_server"' in text
    assert 'resource "coder_app" "opencode"' in text
    assert 'resource "coder_app" "playwright"' in text
    assert 'resource "coder_app" "ssh_login"' in text
    assert "/home/coder/code/Twinbox" in text
    assert 'share        = "owner"' in text
    assert "subdomain    = false" in text
    assert "netbirdio/netbird:${var.netbird_version}-rootless" in text
    assert 'name  = "NB_USE_NETSTACK_MODE"' in text
    assert 'name  = "NB_SOCKS5_LISTENER_PORT"' in text
    assert 'value = "1080"' in text
    assert 'name  = "NB_SOCKS5_LISTENER_ADDRESS"' in text
    assert 'value = "127.0.0.1"' in text
    assert 'service_account_name = "twinbox-dev-admin"' in text
    assert 'mount_path = "/opt/twinbox-opkssh/config.yml"' in text
    assert 'mount_path = "/home/coder/.opk/config.yml"' not in text
    assert 'name  = "OPENCODE_CONFIG"' in text
    assert 'value = "/opt/twinbox-opencode/opencode.json"' in text
    assert 'name = "OPENAI_API_KEY"' in text
    assert 'name = "coder-workspace-ai-provider"' in text
    assert 'mount_path = "/opt/twinbox-opencode/opencode.json"' in text
    assert 'secret_name = "coder-workspace-ai-provider"' in text
    assert 'key  = "OPENCODE_CONFIG_JSON"' in text
    assert 'storage = "50Gi"' in text
    assert 'cpu    = "4"' in text
    assert 'memory = "8Gi"' in text
    assert "privileged" not in text
    assert "/dev/net/tun" not in text


def test_dev_workspace_ships_requested_skills_for_codex_and_opencode():
    required_skills = {
        "argocd-expert",
        "kubernetes-specialist",
        "talos-os-expert",
        "proxmox-admin",
        "hetzner-server",
        "docker-expert",
        "ssh",
        "bash-linux",
        "traefik",
        "cloudflare",
        "frontend-design",
        "ui-ux-pro-max",
        "web-design-guidelines",
        "vercel-react-best-practices",
        "playwright",
        "playwright-cli",
        "playwright-trace",
        "gh-cli",
        "gh-address-comments",
        "dev",
        "customize-opencode",
        "find-skills",
        "writing-skills",
        "brainstorming",
        "writing-plans",
        "executing-plans",
        "subagent-driven-development",
        "test-driven-development",
        "systematic-debugging",
        "requesting-code-review",
        "receiving-code-review",
        "verification-before-completion",
        "finishing-a-development-branch",
        "dispatching-parallel-agents",
        "using-git-worktrees",
        "using-superpowers",
    }

    present_skills = {path.parent.name for path in WORKSPACE_SKILLS.glob("*/SKILL.md")}
    assert required_skills <= present_skills
    assert not list(WORKSPACE_SKILLS.glob("**/node_modules"))


def test_workspace_namespace_grants_explicit_debug_access():
    rbac_text = (WORKSPACE_NAMESPACE / "rbac.yaml").read_text(encoding="utf-8")
    limit_text = (WORKSPACE_NAMESPACE / "limitrange.yaml").read_text(encoding="utf-8")
    externalsecret_text = (WORKSPACE_NAMESPACE / "externalsecret.yaml").read_text(encoding="utf-8")

    assert "name: twinbox-dev-admin" in rbac_text
    assert "name: cluster-admin" in rbac_text
    assert 'cpu: "5"' in limit_text
    assert 'memory: "9Gi"' in limit_text
    assert 'cpu: "4"' in limit_text
    assert 'memory: "8Gi"' in limit_text
    assert "twinbox/global/netbird-dev-workspaces" in externalsecret_text
    assert "twinbox/global/opkssh" in externalsecret_text
    assert "name: coder-workspace-ai-provider" in externalsecret_text
    assert "twinbox/global/twinbox-ai" in externalsecret_text
    assert "OPENAI_API_KEY" in externalsecret_text
    assert "OPENCODE_CONFIG_JSON" in externalsecret_text

    network_policy = (WORKSPACE_NAMESPACE / "networkpolicy.yaml").read_text(encoding="utf-8")
    assert "kind: NetworkPolicy" in network_policy
    assert "coder-workspaces-deny-cross-pod-ingress" in network_policy
    assert "policyTypes:" in network_policy
    assert "- Ingress" in network_policy


def test_install_coder_prepares_workspace_runtime_config_without_fixed_ips():
    text = INSTALL_CODER.read_text(encoding="utf-8")

    assert 'CODER_REDIRECT_URI="${CODER_HOST}/api/v2/users/oidc/callback"' in text
    assert 'CODER_REDIRECT_URI="${CODER_HOST}/oauth/callback"' not in text
    assert "publish_coder_workspace_access" in text
    assert "coder-workspace-access" in text
    assert "discover_management_netbird_ip" in text
    assert "discover_bastion_netbird_ip" in text
    assert "netbird_peer_ip_by_name" in text
    assert "TWINBOX_MANAGEMENT_VM_NETBIRD_IP" in text
    assert "TWINBOX_BASTION_NETBIRD_IP" in text
    assert "coder templates push twinbox-development" in text
    assert "CODER_SESSION_TOKEN" in text
    assert "start_coder_port_forward" in text
    assert "ensure_coder_template_session_token" in text
    assert "CODER_FIRST_USER_USERNAME" in text
    assert "CODER_TEMPLATE_SESSION_TOKEN" in text
    assert 'timeout 90s coder login "$coder_port_forward_url"' in text
    assert "skipping automatic template push" not in text
    assert "ghcr.io/harrywesterman/twinbox-dev-workspace:sha-" in text
    assert "workspace_template: $workspace_template" in text
    assert "192.168." not in text


def test_dev_workspace_access_helpers_use_runtime_contracts():
    tb_text = WORKSPACE_TB.read_text(encoding="utf-8")
    login_text = WORKSPACE_SSH_LOGIN.read_text(encoding="utf-8")

    assert "remote_talos()" in tb_text
    assert "/opt/twinbox/bootstrap" in tb_text
    assert "/secrets/cluster/${cluster_id}/talosconfig/talosconfig" in tb_text
    assert "sudo -n talosctl --talosconfig" in tb_text
    assert "remote_mgmt talosctl --talosconfig /home/twinbox/.talos/config" not in tb_text
    assert 're.search(r"https?://\\S+", line)' in login_text
    assert 're.search(r"https?://\\\\S+", line)' not in login_text
    assert "remember_callback_ports(line)" in login_text
    assert 're.fullmatch(r"[A-Za-z0-9._:-]+", host)' in login_text


def test_manager_worker_ships_pinned_coder_cli_for_template_push():
    text = MANAGER_WORKER_DOCKERFILE.read_text(encoding="utf-8")

    assert "coder_${PINNED_CODER_CHART_VERSION}_linux_amd64.tar.gz" in text
    assert "coder_${PINNED_CODER_CHART_VERSION}_checksums.txt" in text
    assert "tar -xzf /tmp/coder.tar.gz -C /tmp ./coder" in text
    assert "install -m 0755 /tmp/coder /usr/local/bin/coder" in text
    assert "coreutils" in text
    assert "netcat-openbsd" in text


def test_netbird_and_opkssh_have_workspace_contracts():
    network_text = (
        WORKSPACE_ROOT / "infra" / "opentofu" / "netbird-network" / "main.tf"
    ).read_text(encoding="utf-8")
    outputs_text = (
        WORKSPACE_ROOT / "infra" / "opentofu" / "netbird-network" / "outputs.tf"
    ).read_text(encoding="utf-8")
    ingress_text = (
        WORKSPACE_ROOT
        / "categories"
        / "talos-cluster"
        / "steps"
        / "configure-netbird-ingress"
        / "run.sh"
    ).read_text(encoding="utf-8")
    opkssh_text = OPKSSH_SETUP.read_text(encoding="utf-8")

    assert 'resource "netbird_group" "dev_workspaces"' in network_text
    assert 'resource "netbird_setup_key" "dev_workspaces"' in network_text
    assert 'resource "netbird_policy" "dev_workspaces_to_management_vm_ssh"' in network_text
    assert 'resource "netbird_policy" "dev_workspaces_to_management_vm_web"' in network_text
    assert 'resource "netbird_policy" "dev_workspaces_to_management_vm_api"' in network_text
    assert 'resource "netbird_policy" "dev_workspaces_to_bastion_ssh"' in network_text
    assert 'output "dev_workspaces_group_id"' in outputs_text
    assert 'output "dev_workspaces_setup_key"' in outputs_text
    assert "netbird-dev-workspaces" in ingress_text
    assert "DEV_WORKSPACES_GROUP_ID" in ingress_text
    assert "public_zone_regex=" in opkssh_text
    assert (
        'opkssh_coder_redirect_uri_regex="^https://coder[.]${public_zone_regex}/.*callback.*$"'
        in opkssh_text
    )
    assert 'matching_mode: "regex"' in opkssh_text


def test_ci_publishes_and_static_checks_dev_workspace():
    publish_text = PUBLISH_WORKFLOW.read_text(encoding="utf-8")
    verify_text = VERIFY_WORKFLOW.read_text(encoding="utf-8")

    assert "twinbox_dev_workspace" in publish_text
    assert '"image_name": "twinbox-dev-workspace"' in publish_text
    assert '"package_name": "twinbox-dev-workspace"' in publish_text
    assert '"context": "./images/twinbox-dev-workspace"' in publish_text
    assert "images/twinbox-dev-workspace/bin/tb" in verify_text
    assert "images/twinbox-dev-workspace/bin/twinbox-dev-startup" in verify_text
    assert "python -m py_compile images/twinbox-dev-workspace/bin/twinbox-ssh-login" in verify_text
