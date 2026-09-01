"""Regression tests for the copyparty Twinbox integration."""

from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[1]
COPYPARTY_DIR = REPO_ROOT / "gitops" / "platform-apps" / "copyparty"


def _load_yaml(path):
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def _load_yaml_docs(path):
    return list(yaml.safe_load_all(path.read_text(encoding="utf-8")))


def test_copyparty_optional_appset_uses_twinbox_label_flow():
    appset = _load_yaml(REPO_ROOT / "gitops" / "optional-apps" / "copyparty.yaml")
    direct_app = _load_yaml(REPO_ROOT / "gitops" / "apps" / "copyparty.yaml")

    assert appset["kind"] == "ApplicationSet"
    assert appset["metadata"]["name"] == "copyparty-set"
    selector = appset["spec"]["generators"][0]["clusters"]["selector"]["matchLabels"]
    assert selector["twinbox.io/domain-ready"] == "true"
    assert selector["twinbox.io/app-copyparty"] == "enabled"
    assert appset["spec"]["template"]["spec"]["source"]["path"] == "gitops/platform-apps/copyparty"
    assert direct_app["spec"]["source"]["repoURL"] == "__REPO_URL__"
    assert direct_app["spec"]["source"]["targetRevision"] == "__TARGET_REVISION__"


def test_copyparty_platform_manifests_are_openbao_backed_and_persistent():
    kustomization = _load_yaml(COPYPARTY_DIR / "kustomization.yaml")
    deployment = _load_yaml(COPYPARTY_DIR / "deployment.yaml")
    pvc = _load_yaml(COPYPARTY_DIR / "pvc.yaml")
    externalsecret = _load_yaml(COPYPARTY_DIR / "externalsecret.yaml")
    configmap = _load_yaml(COPYPARTY_DIR / "configmap.yaml")

    assert "externalsecret.yaml" in kustomization["resources"]
    assert "configmap.yaml" in kustomization["resources"]
    assert "authentik-forwardauth-middleware.yaml" in kustomization["resources"]
    assert "netbird-forwarded-headers-middleware.yaml" in kustomization["resources"]

    container = deployment["spec"]["template"]["spec"]["containers"][0]
    assert deployment["spec"]["strategy"]["type"] == "Recreate"
    assert deployment["spec"]["template"]["spec"]["enableServiceLinks"] is False
    assert container["image"] == "ghcr.io/9001/copyparty-ac:1.20.21"
    assert container["ports"] == [{"name": "http", "containerPort": 3923}]
    assert container["envFrom"] == [{"secretRef": {"name": "copyparty-config"}}]
    assert container["resources"]["requests"]
    assert container["resources"]["limits"]

    mounted_claims = {
        mount["mountPath"]: mount["subPath"]
        for mount in container["volumeMounts"]
        if mount["name"] == "copyparty-data"
    }
    assert mounted_claims == {"/cfg": "cfg", "/w/data": "data"}
    assert pvc["spec"]["storageClassName"] == "longhorn"
    assert pvc["spec"]["resources"]["requests"]["storage"] == "50Gi"

    assert externalsecret["spec"]["secretStoreRef"] == {
        "name": "openbao",
        "kind": "ClusterSecretStore",
    }
    secret_refs = {
        item["secretKey"]: item["remoteRef"]["key"] for item in externalsecret["spec"]["data"]
    }
    assert secret_refs == {
        "COPYPARTY_ADMIN_USERNAME": "twinbox/global/copyparty",
        "COPYPARTY_ADMIN_PASSWORD": "twinbox/global/copyparty",
        "COPYPARTY_FKEY_SALT": "twinbox/global/copyparty",
        "COPYPARTY_DKEY_SALT": "twinbox/global/copyparty",
    }

    config_template = configmap["data"]["copyparty.conf.tpl"]
    assert "[accounts]" in config_template
    assert "${COPYPARTY_ADMIN_USERNAME}: ${COPYPARTY_ADMIN_PASSWORD}" in config_template
    assert "A: ${COPYPARTY_ADMIN_USERNAME}" in config_template
    assert "rproxy: 1" in config_template
    assert "rw: *" not in config_template


def test_copyparty_routes_are_authentik_protected_on_both_entrypoints():
    ingressroutes = {
        doc["metadata"]["name"]: doc
        for doc in _load_yaml_docs(COPYPARTY_DIR / "ingressroute.yaml")
        if doc and doc.get("kind") == "IngressRoute"
    }
    middleware = _load_yaml(COPYPARTY_DIR / "netbird-forwarded-headers-middleware.yaml")

    assert set(ingressroutes) == {"copyparty", "copyparty-netbird"}
    assert ingressroutes["copyparty"]["spec"]["entryPoints"] == ["websecure"]
    assert ingressroutes["copyparty-netbird"]["spec"]["entryPoints"] == ["webnetbird"]

    public_route = ingressroutes["copyparty"]["spec"]["routes"][0]
    netbird_route = ingressroutes["copyparty-netbird"]["spec"]["routes"][0]
    assert public_route["match"] == "Host(`copyparty.__ZONE_NAME__`)"
    assert netbird_route["match"] == public_route["match"]
    assert public_route["services"] == netbird_route["services"]
    assert public_route["middlewares"] == [{"name": "authentik-forwardauth"}]
    assert netbird_route["middlewares"] == [
        {"name": "copyparty-netbird-forwarded-headers"},
        {"name": "authentik-forwardauth"},
    ]
    assert middleware["spec"]["headers"]["customRequestHeaders"] == {
        "X-Forwarded-Port": "443",
        "X-Forwarded-Proto": "https",
    }


def test_copyparty_runner_bootstraps_secret_and_optional_app():
    script = (
        REPO_ROOT / "categories" / "apps" / "steps" / "install-copyparty" / "run.sh"
    ).read_text(encoding="utf-8")

    assert 'source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"' in script
    assert 'source "$WORKSPACE_ROOT/scripts/manager/authentik-auth.sh"' in script
    assert "openbao_read_global_secret_json copyparty" in script
    assert '--secret-name "copyparty"' in script
    assert (
        "COPYPARTY_ADMIN_USERNAME,COPYPARTY_ADMIN_PASSWORD,COPYPARTY_FKEY_SALT,COPYPARTY_DKEY_SALT"
        in script
    )
    assert 'create_or_update_proxy_provider "copyparty"' in script
    assert '--manifest "$WORKSPACE_ROOT/gitops/optional-apps/copyparty.yaml"' in script
    assert '--application "copyparty"' in script
    assert 'wait_for_resource_ready "copyparty" "externalsecret/copyparty-config"' in script
    assert 'wait_for_pvc_bound "copyparty" "copyparty-data"' in script
    assert 'wait_for_deployment_rollout "copyparty" "copyparty"' in script
