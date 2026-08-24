"""Tests for Twinbox Portal GitOps manifests."""

import pathlib

import yaml

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
PORTAL_DIR = REPO_ROOT / "gitops" / "platform-apps" / "twinbox-portal"


def _load_yaml(path):
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def test_portal_kustomization_includes_netbird_route():
    kust = _load_yaml(PORTAL_DIR / "kustomization.yaml")

    assert "ingressroute.yaml" in kust["resources"]
    assert "ingressroute-netbird.yaml" in kust["resources"]
    assert "netbird-forwarded-headers-middleware.yaml" in kust["resources"]


def test_portal_ingressroutes_cover_public_and_netbird_entrypoints():
    websecure = _load_yaml(PORTAL_DIR / "ingressroute.yaml")
    netbird = _load_yaml(PORTAL_DIR / "ingressroute-netbird.yaml")

    assert websecure["metadata"]["name"] == "twinbox-portal"
    assert websecure["spec"]["entryPoints"] == ["websecure"]
    assert websecure["spec"]["tls"] == {}

    assert netbird["metadata"]["name"] == "twinbox-portal-netbird"
    assert netbird["spec"]["entryPoints"] == ["webnetbird"]
    assert "tls" not in netbird["spec"]
    assert netbird["spec"]["routes"][0]["middlewares"] == [
        {"name": "twinbox-portal-netbird-forwarded-headers"}
    ]

    for route in (websecure, netbird):
        assert route["metadata"]["namespace"] == "twinbox-portal"
        assert route["spec"]["routes"][0]["match"] == "Host(`portal.__ZONE_NAME__`)"
        service = route["spec"]["routes"][0]["services"][0]
        assert service["name"] == "twinbox-portal"
        assert service["port"] == 80


def test_portal_netbird_route_forces_public_https_forwarded_headers():
    middleware = _load_yaml(PORTAL_DIR / "netbird-forwarded-headers-middleware.yaml")

    assert middleware["kind"] == "Middleware"
    assert middleware["metadata"]["name"] == "twinbox-portal-netbird-forwarded-headers"
    assert middleware["metadata"]["namespace"] == "twinbox-portal"
    headers = middleware["spec"]["headers"]["customRequestHeaders"]
    assert headers["X-Forwarded-Proto"] == "https"
    assert headers["X-Forwarded-Port"] == "443"


def test_portal_uses_internal_mailu_api_service():
    deployment = _load_yaml(PORTAL_DIR / "deployment.yaml")
    container = deployment["spec"]["template"]["spec"]["containers"][0]
    env = {entry["name"]: entry["value"] for entry in container["env"]}

    assert env["MAILU_API_BASE_URL"] == "http://mailu-front.mailu.svc.cluster.local/api"


def test_portal_argocd_app_patches_both_ingressroutes():
    app = _load_yaml(REPO_ROOT / "gitops" / "apps" / "twinbox-portal.yaml")
    patches = app["spec"]["source"]["kustomize"]["patches"]
    patches_by_name = {patch["target"]["name"]: patch["patch"] for patch in patches}

    assert "twinbox-portal" in patches_by_name
    assert "twinbox-portal-netbird" in patches_by_name
    assert "Host(`portal.__ZONE_NAME__`)" in patches_by_name["twinbox-portal"]
    assert "Host(`portal.__ZONE_NAME__`)" in patches_by_name["twinbox-portal-netbird"]
