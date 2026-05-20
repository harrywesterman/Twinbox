"""Tests for AdGuard Home GitOps manifests."""
import yaml
import pathlib

GITOPS_DIR = pathlib.Path(__file__).parent.parent / "gitops" / "platform-apps" / "adguard"


def test_namespace_exists():
    ns = yaml.safe_load((GITOPS_DIR / "namespace.yaml").read_text())
    assert ns["kind"] == "Namespace"
    assert ns["metadata"]["name"] == "adguard"


def test_daemonset_exists():
    ds = yaml.safe_load((GITOPS_DIR / "daemonset.yaml").read_text())
    assert ds["kind"] == "DaemonSet"
    assert ds["metadata"]["name"] == "adguard"


def test_daemonset_no_host_network():
    ds = yaml.safe_load((GITOPS_DIR / "daemonset.yaml").read_text())
    spec = ds["spec"]["template"]["spec"]
    assert spec.get("hostNetwork", False) is False


def test_daemonset_uses_pinned_image():
    ds = yaml.safe_load((GITOPS_DIR / "daemonset.yaml").read_text())
    image = ds["spec"]["template"]["spec"]["containers"][0]["image"]
    assert "adguard/adguardhome" in image
    assert ":latest" not in image
    assert ":" in image


def test_daemonset_dns_ports():
    ds = yaml.safe_load((GITOPS_DIR / "daemonset.yaml").read_text())
    ports = ds["spec"]["template"]["spec"]["containers"][0]["ports"]
    port_numbers = [p["containerPort"] for p in ports]
    assert 53 in port_numbers


def test_daemonset_config_mount():
    ds = yaml.safe_load((GITOPS_DIR / "daemonset.yaml").read_text())
    mounts = ds["spec"]["template"]["spec"]["containers"][0]["volumeMounts"]
    config_mounts = [m for m in mounts if m["mountPath"] == "/opt/adguardhome/conf"]
    assert len(config_mounts) == 1
    assert config_mounts[0]["name"] == "config"


def test_daemonset_resources():
    ds = yaml.safe_load((GITOPS_DIR / "daemonset.yaml").read_text())
    resources = ds["spec"]["template"]["spec"]["containers"][0].get("resources", {})
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


def test_configmap_exists():
    cm = yaml.safe_load((GITOPS_DIR / "configmap.yaml").read_text())
    assert cm["kind"] == "ConfigMap"
    assert cm["metadata"]["name"] == "adguard-config"
    assert "AdGuardHome.yaml" in cm["data"]
    assert "upstream_dns" in cm["data"]["AdGuardHome.yaml"]


def test_kustomization_resources():
    kust = yaml.safe_load((GITOPS_DIR / "kustomization.yaml").read_text())
    expected = ["namespace.yaml", "configmap.yaml", "daemonset.yaml", "service.yaml"]
    assert sorted(kust["resources"]) == sorted(expected)
