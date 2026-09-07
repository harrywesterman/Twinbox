"""Tests for the dedicated SeaweedFS backup S3 VM admin GitOps manifests."""

import pathlib

import yaml

GITOPS_DIR = pathlib.Path(__file__).parent.parent / "gitops" / "platform-apps" / "backup-s3"
APPS_DIR = pathlib.Path(__file__).parent.parent / "gitops" / "apps"


def test_namespace_exists():
    ns = yaml.safe_load((GITOPS_DIR / "namespace.yaml").read_text())
    assert ns["kind"] == "Namespace"
    assert ns["metadata"]["name"] == "backup-s3"


def test_service_is_selectorless_cluster_ip():
    svc = yaml.safe_load((GITOPS_DIR / "service.yaml").read_text())
    assert svc["kind"] == "Service"
    assert svc["metadata"]["name"] == "backup-s3"
    assert svc["metadata"]["namespace"] == "backup-s3"
    assert svc["spec"]["type"] == "ClusterIP"
    assert "selector" not in svc["spec"]
    assert svc["spec"]["ports"] == [
        {"name": "https", "port": 8443, "protocol": "TCP", "targetPort": 8443}
    ]


def test_endpoints_target_runtime_backup_s3_vm():
    endpoints = yaml.safe_load((GITOPS_DIR / "endpoints.yaml").read_text())
    assert endpoints["kind"] == "Endpoints"
    assert endpoints["metadata"]["name"] == "backup-s3"
    ip = endpoints["subsets"][0]["addresses"][0]["ip"]
    assert ip == "__BACKUP_S3_HOST_IP__"
    assert endpoints["subsets"][0]["ports"][0]["port"] == 8443


def test_endpoints_not_managed_by_kustomize():
    kust = yaml.safe_load((GITOPS_DIR / "kustomization.yaml").read_text())
    assert "endpoints.yaml" not in kust["resources"]


def test_servers_transport_skips_tls_verify():
    st = yaml.safe_load((GITOPS_DIR / "server-transport.yaml").read_text())
    assert st["kind"] == "ServersTransport"
    assert st["metadata"]["name"] == "backup-s3-server-transport"
    assert st["spec"]["insecureSkipVerify"] is True


def test_ingressroute_has_admin_and_callback_routes():
    docs = list(yaml.safe_load_all((GITOPS_DIR / "ingressroute.yaml").read_text()))
    names = {d["metadata"]["name"] for d in docs}
    assert names == {
        "backup-s3",
        "backup-s3-netbird",
        "backup-s3-authentik-callback",
        "backup-s3-authentik-callback-netbird",
    }


def test_admin_routes_use_forward_auth_to_backup_s3_vm():
    docs = list(yaml.safe_load_all((GITOPS_DIR / "ingressroute.yaml").read_text()))
    for ir in docs:
        if "authentik-callback" in ir["metadata"]["name"]:
            continue
        route = ir["spec"]["routes"][0]
        assert route["match"] == "Host(`backup-s3.__ZONE_NAME__`)"
        assert route["middlewares"] == [
            {"name": "authentik-forwardauth", "namespace": "longhorn-system"}
        ]
        service = route["services"][0]
        assert service["kind"] == "Service"
        assert service["name"] == "backup-s3"
        assert service["port"] == 8443
        assert service["scheme"] == "https"
        assert service["serversTransport"] == "backup-s3-server-transport"


def test_callback_routes_bypass_forward_auth_to_authentik():
    docs = list(yaml.safe_load_all((GITOPS_DIR / "ingressroute.yaml").read_text()))
    for ir in docs:
        if "authentik-callback" not in ir["metadata"]["name"]:
            continue
        route = ir["spec"]["routes"][0]
        assert (
            route["match"]
            == "Host(`backup-s3.__ZONE_NAME__`) && PathPrefix(`/outpost.goauthentik.io`)"
        )
        assert "middlewares" not in route
        assert route["services"] == [
            {"kind": "Service", "name": "authentik-server", "namespace": "authentik", "port": 80}
        ]


def test_ingressroute_websecure_has_tls_and_netbird_does_not():
    docs = list(yaml.safe_load_all((GITOPS_DIR / "ingressroute.yaml").read_text()))
    for ir in docs:
        if ir["spec"]["entryPoints"] == ["websecure"]:
            assert ir["spec"]["tls"] == {}
        elif ir["spec"]["entryPoints"] == ["webnetbird"]:
            assert "tls" not in ir["spec"]


def test_kustomization_resources():
    kust = yaml.safe_load((GITOPS_DIR / "kustomization.yaml").read_text())
    expected = [
        "namespace.yaml",
        "service.yaml",
        "server-transport.yaml",
        "ingressroute.yaml",
    ]
    assert sorted(kust["resources"]) == sorted(expected)


def test_app_manifest_targets_backup_s3_platform_app():
    app = yaml.safe_load((APPS_DIR / "backup-s3.yaml").read_text())
    assert app["kind"] == "Application"
    assert app["metadata"]["name"] == "backup-s3"
    source = app["spec"]["source"]
    assert source["path"] == "gitops/platform-apps/backup-s3"
    assert source["repoURL"] == "__REPO_URL__"
    assert source["targetRevision"] == "__TARGET_REVISION__"
    patch_values = [p["patch"] for p in source["kustomize"]["patches"]]
    assert any("value: Host(`backup-s3.__ZONE_NAME__`)" in v for v in patch_values)
    assert any("PathPrefix(`/outpost.goauthentik.io`)" in v for v in patch_values)
    assert app["spec"]["destination"]["namespace"] == "backup-s3"
