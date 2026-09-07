"""Tests for Proxmox Backup Server (PBS) GitOps manifests."""

import pathlib

import yaml

GITOPS_DIR = pathlib.Path(__file__).parent.parent / "gitops" / "platform-apps" / "pbs"
APPS_DIR = pathlib.Path(__file__).parent.parent / "gitops" / "apps"


def test_namespace_exists():
    ns = yaml.safe_load((GITOPS_DIR / "namespace.yaml").read_text())
    assert ns["kind"] == "Namespace"
    assert ns["metadata"]["name"] == "pbs"


def test_service_is_selectorless_cluster_ip():
    svc = yaml.safe_load((GITOPS_DIR / "service.yaml").read_text())
    assert svc["kind"] == "Service"
    assert svc["metadata"]["name"] == "pbs"
    assert svc["metadata"]["namespace"] == "pbs"
    assert svc["spec"]["type"] == "ClusterIP"
    assert "selector" not in svc["spec"]
    ports = svc["spec"]["ports"]
    assert ports == [{"name": "https", "port": 8007, "protocol": "TCP", "targetPort": 8007}]


def test_endpoints_target_runtime_pbs_vm():
    endpoints = yaml.safe_load((GITOPS_DIR / "endpoints.yaml").read_text())
    assert endpoints["kind"] == "Endpoints"
    assert endpoints["metadata"]["name"] == "pbs"
    ip = endpoints["subsets"][0]["addresses"][0]["ip"]
    assert ip == "__PBS_HOST_IP__"
    assert endpoints["subsets"][0]["ports"][0]["port"] == 8007


def test_endpoints_not_managed_by_kustomize():
    kust = yaml.safe_load((GITOPS_DIR / "kustomization.yaml").read_text())
    assert "endpoints.yaml" not in kust["resources"]


def test_servers_transport_skips_tls_verify():
    st = yaml.safe_load((GITOPS_DIR / "server-transport.yaml").read_text())
    assert st["kind"] == "ServersTransport"
    assert st["metadata"]["name"] == "pbs-server-transport"
    assert st["spec"]["insecureSkipVerify"] is True


def test_ingressroute_has_both_entrypoints():
    docs = list(yaml.safe_load_all((GITOPS_DIR / "ingressroute.yaml").read_text()))
    assert len(docs) == 2
    names = {d["metadata"]["name"] for d in docs}
    assert names == {"pbs", "pbs-netbird"}


def test_ingressroute_routes_to_pbs_vm_over_https():
    docs = list(yaml.safe_load_all((GITOPS_DIR / "ingressroute.yaml").read_text()))
    for ir in docs:
        route = ir["spec"]["routes"][0]
        assert route["match"] == "Host(`pbs.__ZONE_NAME__`)"
        service = route["services"][0]
        assert service["kind"] == "Service"
        assert service["name"] == "pbs"
        assert service["port"] == 8007
        assert service["scheme"] == "https"
        assert service["serversTransport"] == "pbs-server-transport"


def test_ingressroute_uses_native_oidc_not_forward_auth():
    docs = list(yaml.safe_load_all((GITOPS_DIR / "ingressroute.yaml").read_text()))
    for ir in docs:
        assert "middlewares" not in ir["spec"]["routes"][0]


def test_ingressroute_websecure_has_tls():
    docs = list(yaml.safe_load_all((GITOPS_DIR / "ingressroute.yaml").read_text()))
    ir = next(d for d in docs if d["spec"]["entryPoints"] == ["websecure"])
    assert ir["spec"]["tls"] == {}


def test_ingressroute_netbird_no_tls():
    docs = list(yaml.safe_load_all((GITOPS_DIR / "ingressroute.yaml").read_text()))
    ir = next(d for d in docs if d["spec"]["entryPoints"] == ["webnetbird"])
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


def test_app_manifest_targets_pbs_platform_app():
    app = yaml.safe_load((APPS_DIR / "pbs.yaml").read_text())
    assert app["kind"] == "Application"
    assert app["metadata"]["name"] == "pbs"
    source = app["spec"]["source"]
    assert source["path"] == "gitops/platform-apps/pbs"
    assert source["repoURL"] == "__REPO_URL__"
    assert source["targetRevision"] == "__TARGET_REVISION__"
    patch_values = [p["patch"] for p in source["kustomize"]["patches"]]
    assert any("value: Host(`pbs.__ZONE_NAME__`)" in v for v in patch_values)
    assert app["spec"]["destination"]["namespace"] == "pbs"
