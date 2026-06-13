"""Tests for AdGuard Home GitOps manifests."""

import pathlib

import yaml

GITOPS_DIR = pathlib.Path(__file__).parent.parent / "gitops" / "platform-apps" / "adguard"


def test_namespace_exists():
    ns = yaml.safe_load((GITOPS_DIR / "namespace.yaml").read_text())
    assert ns["kind"] == "Namespace"
    assert ns["metadata"]["name"] == "adguard"


def test_deployment_exists():
    deploy = yaml.safe_load((GITOPS_DIR / "deployment.yaml").read_text())
    assert deploy["kind"] == "Deployment"
    assert deploy["metadata"]["name"] == "adguard"


def test_deployment_single_replica():
    deploy = yaml.safe_load((GITOPS_DIR / "deployment.yaml").read_text())
    assert deploy["spec"]["replicas"] == 1


def test_deployment_no_host_network():
    deploy = yaml.safe_load((GITOPS_DIR / "deployment.yaml").read_text())
    spec = deploy["spec"]["template"]["spec"]
    assert spec.get("hostNetwork", False) is False


def test_deployment_uses_pinned_image():
    deploy = yaml.safe_load((GITOPS_DIR / "deployment.yaml").read_text())
    image = deploy["spec"]["template"]["spec"]["containers"][0]["image"]
    assert "adguard/adguardhome" in image
    assert ":latest" not in image
    assert ":" in image


def test_deployment_dns_ports():
    deploy = yaml.safe_load((GITOPS_DIR / "deployment.yaml").read_text())
    ports = deploy["spec"]["template"]["spec"]["containers"][0]["ports"]
    port_numbers = [p["containerPort"] for p in ports]
    assert 53 in port_numbers


def test_deployment_config_mount():
    deploy = yaml.safe_load((GITOPS_DIR / "deployment.yaml").read_text())
    spec = deploy["spec"]["template"]["spec"]
    mounts = deploy["spec"]["template"]["spec"]["containers"][0]["volumeMounts"]
    config_mounts = [m for m in mounts if m["mountPath"] == "/opt/adguardhome/conf"]
    assert len(config_mounts) == 1
    assert config_mounts[0]["name"] == "config"
    config_volumes = [v for v in spec["volumes"] if v["name"] == "config"]
    assert config_volumes[0] == {"name": "config", "emptyDir": {}}


def test_deployment_seeds_config_into_writable_volume():
    deploy = yaml.safe_load((GITOPS_DIR / "deployment.yaml").read_text())
    spec = deploy["spec"]["template"]["spec"]
    init_container = spec["initContainers"][0]
    assert init_container["name"] == "seed-config"
    assert init_container["image"] == "busybox:1.36.1"
    assert any(m["name"] == "config-seed" and m["readOnly"] for m in init_container["volumeMounts"])
    assert any(
        m["name"] == "config" and m["mountPath"] == "/opt/adguardhome/conf"
        for m in init_container["volumeMounts"]
    )
    assert any(
        v["name"] == "config-seed" and v["configMap"]["name"] == "adguard-config"
        for v in spec["volumes"]
    )


def test_deployment_resources():
    deploy = yaml.safe_load((GITOPS_DIR / "deployment.yaml").read_text())
    resources = deploy["spec"]["template"]["spec"]["containers"][0].get("resources", {})
    assert "requests" in resources
    assert "limits" in resources


def test_service_is_cluster_ip():
    svc = yaml.safe_load((GITOPS_DIR / "service.yaml").read_text())
    assert svc["kind"] == "Service"
    assert svc["metadata"]["name"] == "adguard-dns"
    assert svc["spec"].get("clusterIP", None) is None


def test_service_has_dns_ports():
    svc = yaml.safe_load((GITOPS_DIR / "service.yaml").read_text())
    ports = svc["spec"]["ports"]
    udp53 = [p for p in ports if p["port"] == 53 and p["protocol"] == "UDP"]
    tcp53 = [p for p in ports if p["port"] == 53 and p["protocol"] == "TCP"]
    assert len(udp53) == 1
    assert len(tcp53) == 1


def test_service_has_http_port():
    svc = yaml.safe_load((GITOPS_DIR / "service.yaml").read_text())
    ports = svc["spec"]["ports"]
    http = [p for p in ports if p["port"] == 3000 and p["protocol"] == "TCP"]
    assert len(http) == 1
    assert http[0].get("targetPort") == 3000


def test_configmap_exists():
    cm = yaml.safe_load((GITOPS_DIR / "configmap.yaml").read_text())
    assert cm["kind"] == "ConfigMap"
    assert cm["metadata"]["name"] == "adguard-config"
    assert "AdGuardHome.yaml" in cm["data"]
    assert "upstream_dns" in cm["data"]["AdGuardHome.yaml"]


def test_configmap_dns_settings_are_valid_for_netbird_clients():
    cm = yaml.safe_load((GITOPS_DIR / "configmap.yaml").read_text())
    adguard_config = yaml.safe_load(cm["data"]["AdGuardHome.yaml"])
    dns_config = adguard_config["dns"]

    assert dns_config["bootstrap_dns"] == "9.9.9.9"
    assert dns_config["ratelimit"] == 0
    assert {"domain": "bierineenweek.nl", "answer": "188.34.166.172"} in dns_config["rewrites"]
    assert {"domain": "*.bierineenweek.nl", "answer": "188.34.166.172"} in dns_config["rewrites"]


def test_ingressroute_has_both_entrypoints():
    docs = list(yaml.safe_load_all((GITOPS_DIR / "ingressroute.yaml").read_text()))
    assert len(docs) == 2
    names = {d["metadata"]["name"] for d in docs}
    assert names == {"adguard", "adguard-netbird"}


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
        "configmap.yaml",
        "deployment.yaml",
        "service.yaml",
        "ingressroute.yaml",
    ]
    assert sorted(kust["resources"]) == sorted(expected)
