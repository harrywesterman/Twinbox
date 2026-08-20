from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[1]
AUDIOBOOKSHELF_DIR = REPO_ROOT / "gitops" / "platform-apps" / "audiobookshelf"


def test_netbird_route_preserves_public_https_origin_for_openid_callbacks():
    ingress_routes = list(
        yaml.safe_load_all((AUDIOBOOKSHELF_DIR / "ingressroute.yaml").read_text(encoding="utf-8"))
    )
    middleware = yaml.safe_load(
        (AUDIOBOOKSHELF_DIR / "netbird-forwarded-headers-middleware.yaml").read_text(
            encoding="utf-8"
        )
    )

    netbird_route = next(
        route for route in ingress_routes if route["metadata"]["name"] == "audiobookshelf-netbird"
    )

    assert netbird_route["spec"]["entryPoints"] == ["webnetbird"]
    assert netbird_route["spec"]["routes"][0]["middlewares"] == [
        {"name": "audiobookshelf-netbird-forwarded-headers"}
    ]
    assert middleware["metadata"]["namespace"] == "audiobookshelf"
    assert middleware["spec"]["headers"]["customRequestHeaders"] == {
        "X-Forwarded-Port": "443",
        "X-Forwarded-Proto": "https",
    }
