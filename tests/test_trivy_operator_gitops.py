"""Tests for the Trivy Operator GitOps application."""

import pathlib

import yaml

REPO_ROOT = pathlib.Path(__file__).parent.parent
APP_MANIFEST = REPO_ROOT / "gitops" / "apps" / "trivy-operator.yaml"
VALUES_FILE = REPO_ROOT / "gitops" / "values" / "trivy-operator.yaml"
STEP_DIR = REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-trivy-operator"


def test_app_manifest_installs_trivy_operator_chart():
    app = yaml.safe_load(APP_MANIFEST.read_text())
    assert app["kind"] == "Application"
    assert app["metadata"]["name"] == "trivy-operator"
    assert app["metadata"]["namespace"] == "argocd"
    source = app["spec"]["sources"][0]
    assert source["repoURL"] == "https://aquasecurity.github.io/helm-charts"
    assert source["chart"] == "trivy-operator"
    assert source["targetRevision"] == "0.36.0"
    assert source["helm"]["valueFiles"] == ["$values/gitops/values/trivy-operator.yaml"]


def test_app_manifest_uses_values_ref_and_trivy_system_namespace():
    app = yaml.safe_load(APP_MANIFEST.read_text())
    sources = app["spec"]["sources"]
    assert sources[1]["ref"] == "values"
    assert sources[1]["repoURL"] == "__REPO_URL__"
    assert sources[1]["targetRevision"] == "__TARGET_REVISION__"
    assert app["spec"]["destination"]["namespace"] == "trivy-system"
    assert "CreateNamespace=true" in app["spec"]["syncPolicy"]["syncOptions"]


def test_values_enable_operator_scanning_and_metrics():
    values = yaml.safe_load(VALUES_FILE.read_text())
    assert values["operator"]["scanJobsConcurrentLimit"] == 3
    assert values["trivy"]["ignoreUnfixed"] is False
    assert values["serviceMonitor"]["enabled"] is True


def test_step_applies_the_application():
    step = yaml.safe_load((STEP_DIR / "step.yaml").read_text())
    assert step["id"] == "install-trivy-operator"
    assert step["type"] == "action"
    assert step["runner"]["script"] == (
        "categories/talos-cluster/steps/install-trivy-operator/run.sh"
    )
    assert "KUBECONFIG_FILE" in step["secrets"]["files"]

    run_sh = (STEP_DIR / "run.sh").read_text()
    assert "gitops/apps/trivy-operator.yaml" in run_sh
    assert '"trivy-operator"' in run_sh
    assert '"trivy-system"' in run_sh
