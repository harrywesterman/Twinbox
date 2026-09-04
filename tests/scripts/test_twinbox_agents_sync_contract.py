import os
import subprocess
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
AGENTS_INSTALL_STEP_MANIFEST = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-twinbox-agents" / "step.yaml"
)
AGENTS_INSTALL_STEP_RUN = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-twinbox-agents" / "run.sh"
)
SHARED_AI_BASELINE_SCRIPT = REPO_ROOT / "scripts" / "manager" / "ensure-shared-ai-secret.sh"
KUBERNETES_AI_REFRESH_SCRIPT = REPO_ROOT / "scripts" / "manager" / "kubernetes-ai-refresh.sh"


def run_shared_ai_baseline(tmp_path, read_mode):
    workspace = tmp_path / "workspace"
    manager_scripts = workspace / "scripts" / "manager"
    manager_scripts.mkdir(parents=True)
    marker = tmp_path / "sync-called"

    (manager_scripts / "openbao-secret-sync.sh").write_text(
        """#!/usr/bin/env bash
openbao_read_global_secret_json() {
  case "${FAKE_OPENBAO_READ_MODE}" in
    exists) printf '%s\\n' '{"OPENAI_API_KEY":"preserve-me"}' ;;
    missing) echo 'curl: (22) The requested URL returned error: 404' >&2; return 22 ;;
    failure) echo 'curl: (7) Failed to connect to OpenBao' >&2; return 7 ;;
  esac
}
""",
        encoding="utf-8",
    )
    (manager_scripts / "sync-openbao-global-secret.sh").write_text(
        """#!/usr/bin/env bash
set -euo pipefail
: "${FAKE_SYNC_MARKER:?}"
printf 'called\\n' >"$FAKE_SYNC_MARKER"
""",
        encoding="utf-8",
    )

    env = {
        **os.environ,
        "WORKSPACE_ROOT": str(workspace),
        "FAKE_OPENBAO_READ_MODE": read_mode,
        "FAKE_SYNC_MARKER": str(marker),
    }
    result = subprocess.run(
        ["bash", str(SHARED_AI_BASELINE_SCRIPT)],
        cwd=REPO_ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    return result, marker


def test_external_secret_refresh_waits_for_new_sync_token(tmp_path):
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    state_file = tmp_path / "state"
    log_file = tmp_path / "kubectl.log"
    state_file.write_text("before", encoding="utf-8")

    kubectl = fake_bin / "kubectl"
    kubectl.write_text(
        """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >>"$FAKE_KUBECTL_LOG"
if [[ "$*" == *" annotate "* ]]; then
  printf 'first-poll\\n' >"$FAKE_KUBECTL_STATE"
  exit 0
fi
if [[ "$*" == *" get "* && "$*" == *" -o json"* ]]; then
  state="$(cat "$FAKE_KUBECTL_STATE")"
  if [[ "$state" == "first-poll" ]]; then
    printf 'after\\n' >"$FAKE_KUBECTL_STATE"
  fi
  if [[ "$state" == "after" ]]; then
    printf '%s\\n' '{"status":{"refreshTime":"2026-09-03T12:01:00Z","syncedResourceVersion":"2","conditions":[{"type":"Ready","status":"True"}]}}'
  else
    printf '%s\\n' '{"status":{"refreshTime":"2026-09-03T12:00:00Z","syncedResourceVersion":"1","conditions":[{"type":"Ready","status":"True"}]}}'
  fi
  exit 0
fi
exit 1
""",
        encoding="utf-8",
    )
    kubectl.chmod(0o755)

    env = {
        **os.environ,
        "PATH": f"{fake_bin}:{os.environ['PATH']}",
        "FAKE_KUBECTL_LOG": str(log_file),
        "FAKE_KUBECTL_STATE": str(state_file),
        "TWINBOX_EXTERNAL_SECRET_REFRESH_ATTEMPTS": "3",
        "TWINBOX_EXTERNAL_SECRET_REFRESH_POLL_SECONDS": "0",
    }
    result = subprocess.run(
        [
            "bash",
            "-c",
            f'source "{KUBERNETES_AI_REFRESH_SCRIPT}"; '
            'refresh_externalsecret_if_exists "demo" "externalsecret/demo-ai" "123"',
        ],
        cwd=REPO_ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    calls = log_file.read_text(encoding="utf-8").splitlines()
    assert sum(" get " in f" {call} " for call in calls) == 3
    assert any("force-sync=123" in call for call in calls)
    assert state_file.read_text(encoding="utf-8") == "after\n"


def test_external_secret_refresh_skips_missing_app(tmp_path):
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    kubectl = fake_bin / "kubectl"
    kubectl.write_text("#!/usr/bin/env bash\nexit 1\n", encoding="utf-8")
    kubectl.chmod(0o755)

    result = subprocess.run(
        [
            "bash",
            "-c",
            f'source "{KUBERNETES_AI_REFRESH_SCRIPT}"; '
            'refresh_externalsecret_if_exists "missing" "externalsecret/missing-ai" "123"',
        ],
        cwd=REPO_ROOT,
        env={**os.environ, "PATH": f"{fake_bin}:{os.environ['PATH']}"},
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode == 0
    assert "not found in missing, skipping refresh" in result.stdout


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


def test_agent_config_sync_projects_shared_ai_endpoint_to_apps():
    script_text = (REPO_ROOT / "scripts" / "manager" / "sync-twinbox-agents-config.sh").read_text(
        encoding="utf-8"
    )

    assert "sync-twinbox-ai-config: projecting shared AI endpoint" in script_text
    assert "OPENAI_API_BASE_URL" in script_text
    assert "OPENAI_BASE_URL" in script_text
    assert "PAPERLESS_AI_LLM_BACKEND" in script_text
    assert "PAPERLESS_AI_LLM_MODEL" in script_text
    assert "OPENCODE_CONFIG_JSON" in script_text
    assert '"apiKey": "{env:OPENAI_API_KEY}"' in script_text
    assert "OPENCODE_AUTH_JSON" not in script_text
    assert "--secret-name twinbox-ai" in script_text
    assert "externalsecret/openwebui-ai-provider" in script_text
    assert "externalsecret/karakeep-ai-provider" in script_text
    assert "externalsecret/paperless-ai-provider" in script_text
    assert "externalsecret/coder-workspace-ai-provider" in script_text


def test_agent_config_sync_restarts_only_existing_ai_consumers():
    script_text = (REPO_ROOT / "scripts" / "manager" / "sync-twinbox-agents-config.sh").read_text(
        encoding="utf-8"
    )

    for namespace, deployment in [
        ("twinbox-agents", "twinbox-agents"),
        ("openwebui", "openwebui"),
        ("karakeep", "karakeep"),
        ("paperless", "paperless"),
    ]:
        assert f'restart_deployment_if_exists "{namespace}" "{deployment}"' in script_text

    assert 'restart_deployments_by_selector_if_exists "coder-workspaces"' in script_text
    assert '"app.kubernetes.io/name=twinbox-dev-workspace"' in script_text
    assert "deployment not found in" in script_text
    assert "rollout restart deployment/" in script_text


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
    assert "kubernetes-ai-refresh.sh" in script_text
    assert "refresh_externalsecret_if_exists" in script_text
    assert "--for=condition=Ready" not in script_text
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


def test_ai_consuming_app_install_steps_resync_shared_endpoint_when_configured():
    for step in ["install-openwebui", "install-karakeep", "install-paperless", "install-coder"]:
        script_text = (REPO_ROOT / "categories" / "apps" / "steps" / step / "run.sh").read_text(
            encoding="utf-8"
        )

        assert "ensure_shared_ai_secret_baseline" in script_text
        assert "ensure-shared-ai-secret.sh" in script_text
        assert "sync_shared_ai_endpoint_if_configured" in script_text
        assert "manager-data/agents/provider.json" not in script_text
        assert "sync-twinbox-agents-config.sh" in script_text
        assert 'MANAGER_DATA_DIR="${MANAGER_DATA_DIR:-/data}"' in script_text


def test_shared_ai_secret_baseline_seeds_empty_safe_defaults():
    script_text = (REPO_ROOT / "scripts" / "manager" / "ensure-shared-ai-secret.sh").read_text(
        encoding="utf-8"
    )

    assert "openbao_read_global_secret_json twinbox-ai" in script_text
    assert "--secret-name twinbox-ai" in script_text
    assert 'OPENAI_API_BASE_URL: ""' in script_text
    assert 'OPENAI_API_KEY: ""' in script_text
    assert 'PAPERLESS_AI_ENABLED: "false"' in script_text
    assert 'OPENCODE_CONFIG_JSON: "{}"' in script_text
    assert "OPENCODE_AUTH_JSON" not in script_text
    assert "--required-keys" not in script_text
    assert "sk-" not in script_text
    assert "api key" not in script_text.lower()


def test_shared_ai_secret_baseline_seeds_only_after_confirmed_not_found(tmp_path):
    result, marker = run_shared_ai_baseline(tmp_path, "missing")

    assert result.returncode == 0, result.stderr
    assert marker.exists()


def test_shared_ai_secret_baseline_preserves_existing_secret_on_read_failure(tmp_path):
    result, marker = run_shared_ai_baseline(tmp_path, "failure")

    assert result.returncode != 0
    assert "Failed to connect to OpenBao" in result.stderr
    assert not marker.exists()


def test_ci_static_checks_include_twinbox_agents_scripts():
    verify_text = (REPO_ROOT / ".github" / "workflows" / "verify.yml").read_text(encoding="utf-8")

    assert "categories/talos-cluster/steps/install-twinbox-agents/run.sh" in verify_text
    assert "scripts/manager/sync-twinbox-agents-config.sh" in verify_text
    assert "scripts/manager/ensure-shared-ai-secret.sh" in verify_text
