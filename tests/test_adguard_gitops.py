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
    assert ds["spec"]["template"]["spec"]["hostNetwork"] is True


def test_daemonset_uses_adguard_image():
    ds = yaml.safe_load((GITOPS_DIR / "daemonset.yaml").read_text())
    containers = ds["spec"]["template"]["spec"]["containers"]
    assert len(containers) == 1
    assert "adguard/adguardhome" in containers[0]["image"]


def test_daemonset_dns_ports():
    ds = yaml.safe_load((GITOPS_DIR / "daemonset.yaml").read_text())
    ports = ds["spec"]["template"]["spec"]["containers"][0]["ports"]
    port_numbers = [p["containerPort"] for p in ports]
    assert 53 in port_numbers


def test_headless_service():
    svc = yaml.safe_load((GITOPS_DIR / "headless-service.yaml").read_text())
    assert svc["kind"] == "Service"
    assert svc["spec"]["clusterIP"] == "None"
    assert svc["spec"]["publishNotReadyAddresses"] is True


def test_kustomization_resources():
    kust = yaml.safe_load((GITOPS_DIR / "kustomization.yaml").read_text())
    expected = ["namespace.yaml", "daemonset.yaml", "headless-service.yaml"]
    assert kust["resources"] == expected
