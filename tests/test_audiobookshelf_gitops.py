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


def test_deployment_applies_oidc_admin_permissions_patch_before_startup():
    deployment = yaml.safe_load(
        (AUDIOBOOKSHELF_DIR / "deployment.yaml").read_text(encoding="utf-8")
    )
    kustomization = yaml.safe_load(
        (AUDIOBOOKSHELF_DIR / "kustomization.yaml").read_text(encoding="utf-8")
    )
    patch_config = yaml.safe_load(
        (AUDIOBOOKSHELF_DIR / "oidc-admin-permissions-patch.yaml").read_text(encoding="utf-8")
    )

    container = deployment["spec"]["template"]["spec"]["containers"][0]
    volume_mounts = container["volumeMounts"]
    volumes = deployment["spec"]["template"]["spec"]["volumes"]
    patch_script = patch_config["data"]["patch-oidc-admin-permissions.mjs"]

    assert "oidc-admin-permissions-patch.yaml" in kustomization["resources"]
    assert container["command"] == [
        "tini",
        "--",
        "sh",
        "-lc",
        "node /opt/twinbox/patch-oidc-admin-permissions.mjs && exec node index.js",
    ]
    assert {
        "name": "oidc-admin-permissions-patch",
        "mountPath": "/opt/twinbox/patch-oidc-admin-permissions.mjs",
        "subPath": "patch-oidc-admin-permissions.mjs",
        "readOnly": True,
    } in volume_mounts
    assert {
        "name": "oidc-admin-permissions-patch",
        "configMap": {"name": "audiobookshelf-oidc-admin-permissions-patch"},
    } in volumes
    assert "userType === 'admin'" in patch_script
    assert "getDefaultPermissionsForUserType('admin')" in patch_script
    assert "delete: currentPermissions.delete === true" in patch_script
    assert "Applying admin permissions" in patch_script
