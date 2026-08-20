from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[1]
HEDGEDOC_DIR = REPO_ROOT / "gitops" / "platform-apps" / "hedgedoc"


def test_netbird_route_preserves_public_https_origin_for_oauth2_sessions():
    kustomization = yaml.safe_load(
        (HEDGEDOC_DIR / "kustomization.yaml").read_text(encoding="utf-8")
    )
    ingress_routes = list(
        yaml.safe_load_all((HEDGEDOC_DIR / "ingressroute.yaml").read_text(encoding="utf-8"))
    )
    middleware = yaml.safe_load(
        (HEDGEDOC_DIR / "netbird-forwarded-headers-middleware.yaml").read_text(encoding="utf-8")
    )

    netbird_route = next(
        route for route in ingress_routes if route["metadata"]["name"] == "hedgedoc-netbird"
    )

    assert "netbird-forwarded-headers-middleware.yaml" in kustomization["resources"]
    assert netbird_route["spec"]["entryPoints"] == ["webnetbird"]
    assert netbird_route["spec"]["routes"][0]["middlewares"] == [
        {"name": "hedgedoc-netbird-forwarded-headers"}
    ]
    assert middleware["metadata"]["namespace"] == "hedgedoc"
    assert middleware["spec"]["headers"]["customRequestHeaders"] == {
        "X-Forwarded-Port": "443",
        "X-Forwarded-Proto": "https",
    }
