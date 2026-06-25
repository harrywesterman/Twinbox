from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
AGENTS_INSTALL_STEP_MANIFEST = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-twinbox-agents" / "step.yaml"
)
AGENTS_INSTALL_STEP_RUN = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-twinbox-agents" / "run.sh"
)


def test_agent_config_sync_runs_even_without_provider_config():
    worker_text = (REPO_ROOT / "manager-worker" / "src" / "worker.js").read_text(encoding="utf-8")
    script_text = (REPO_ROOT / "scripts" / "manager" / "sync-twinbox-agents-config.sh").read_text(
        encoding="utf-8"
    )

    assert "provider config not found, skipping" not in worker_text
    assert "provider config not found; runtime secret will still be synced" in script_text
    assert script_text.index("syncing runtime secret to OpenBao") < script_text.index(
        "applying provider configmap"
    )


def test_agent_config_sync_uses_bootstrap_secret_paths():
    script_text = (REPO_ROOT / "scripts" / "manager" / "sync-twinbox-agents-config.sh").read_text(
        encoding="utf-8"
    )

    assert (
        'TWINBOX_BOOTSTRAP_DIR="${TWINBOX_BOOTSTRAP_DIR:-${WORKSPACE_ROOT}/bootstrap}"'
        in script_text
    )
    assert "${TWINBOX_BOOTSTRAP_DIR}/secrets/global/twinbox-agents.json" in script_text
    assert (
        "${TWINBOX_BOOTSTRAP_DIR}/secrets/cluster/${CLUSTER_ID}/kubeconfig/kubeconfig"
        in script_text
    )
    assert 'CLUSTER_ID="${TWINBOX_CLUSTER_ID:-}"' in script_text
    assert "using kubeconfig for requested cluster" in script_text
    assert "using fallback kubeconfig for cluster" in script_text
    assert "wait \\" in script_text
    assert "externalsecret/twinbox-agents-runtime" in script_text
    assert "${MANAGER_DATA_DIR}/bootstrap" not in script_text


def test_twinbox_agents_has_web_wizard_install_step():
    step = yaml.safe_load(AGENTS_INSTALL_STEP_MANIFEST.read_text(encoding="utf-8"))

    assert step["id"] == "install-twinbox-agents"
    assert step["title"] == "Install AI Beheerteam"
    assert step["type"] == "action"
    assert step["journey_stage"] == "setup"
    assert step["inputs"] == []
    assert (
        step["runner"]["script"] == "categories/talos-cluster/steps/install-twinbox-agents/run.sh"
    )
    assert step["secrets"]["files"]["KUBECONFIG_FILE"]["scope"] == "cluster"
    assert step["secrets"]["files"]["KUBECONFIG_FILE"]["item"] == "kubeconfig"


def test_twinbox_agents_install_step_applies_argocd_app_and_secret_plumbing():
    script_text = AGENTS_INSTALL_STEP_RUN.read_text(encoding="utf-8")

    assert "gitops/apps/twinbox-agents.yaml" in script_text
    assert "gitops/platform-apps/twinbox-portal/agents-externalsecret.yaml" in script_text
    assert "sync-openbao-global-secret.sh" in script_text
    assert '--secret-name "twinbox-agents"' in script_text
    assert '--required-keys "TWINBOX_AGENT_INTERNAL_TOKEN"' in script_text
    assert "apply-argocd-application.sh" in script_text
    assert '--application "twinbox-agents"' in script_text
    assert '--destination-namespace "$AGENTS_NAMESPACE"' in script_text
    assert ". + {TWINBOX_AGENT_INTERNAL_TOKEN: $token}" in script_text
    assert "rollout status deployment/twinbox-agents" in script_text
    assert "rollout restart deployment/twinbox-agents" in script_text
    assert "rollout restart deployment/twinbox-portal" in script_text
    assert "OPENAI_API_KEY=" not in script_text


def test_ci_static_checks_include_twinbox_agents_scripts():
    verify_text = (REPO_ROOT / ".github" / "workflows" / "verify.yml").read_text(encoding="utf-8")

    assert "categories/talos-cluster/steps/install-twinbox-agents/run.sh" in verify_text
    assert "scripts/manager/sync-twinbox-agents-config.sh" in verify_text
