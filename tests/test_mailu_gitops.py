"""Tests for Mailu GitOps manifests and installer contracts."""

import json
import pathlib
import subprocess

import yaml

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
MAILU_PLATFORM_DIR = REPO_ROOT / "gitops" / "platform-apps" / "mailu"


def _load_yaml(path):
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def test_mailu_optional_appset_uses_pinned_mailu_chart():
    appset = _load_yaml(REPO_ROOT / "gitops" / "optional-apps" / "mailu.yaml")
    assert appset["kind"] == "ApplicationSet"
    assert appset["metadata"]["name"] == "mailu-set"
    selector = appset["spec"]["generators"][0]["clusters"]["selector"]["matchLabels"]
    assert selector["twinbox.io/domain-ready"] == "true"
    assert selector["twinbox.io/app-mailu"] == "enabled"

    helm_source = appset["spec"]["template"]["spec"]["sources"][0]
    assert helm_source["repoURL"] == "https://mailu.github.io/helm-charts"
    assert helm_source["chart"] == "mailu"
    assert helm_source["targetRevision"] == "2.7.1"
    assert "missingkey=error" in appset["spec"]["goTemplateOptions"]

    direct_app_text = (REPO_ROOT / "gitops" / "apps" / "mailu.yaml").read_text(encoding="utf-8")
    relay_host = "[mailu-relay-egress.netbird.svc.cluster.local]:2525"
    assert relay_host in helm_source["helm"]["values"]
    assert "__MAILU_RELAY_TARGET_HOST__" in direct_app_text
    assert "__MAILU_RELAY_HOST__" not in direct_app_text
    assert "mail.__ZONE_NAME__:2525" not in direct_app_text


def test_mailu_values_keep_mail_ports_internal_and_set_resources():
    values = _load_yaml(REPO_ROOT / "gitops" / "values" / "mailu.yaml")
    assert values["mailuVersion"] == "2024.06.52"
    assert values["ingress"]["enabled"] is False
    assert values["front"]["hostPort"]["enabled"] is False
    assert values["front"]["externalService"]["enabled"] is False
    assert values["api"]["enabled"] is True
    assert values["api"]["existingSecret"] == "mailu-runtime"
    assert values["externalRelay"]["existingSecret"] == "mailu-relay"
    assert values["persistence"]["storageClass"] == "longhorn-single"
    assert values["persistence"]["single_pvc"] is True
    assert values["persistence"]["accessModes"] == ["ReadWriteOnce"]
    assert values["tika"]["enabled"] is False

    assert values["proxyAuth"]["create"] == "false"
    assert values["proxyAuth"]["header"] == ""
    assert values["proxyAuth"]["whitelist"] == ""

    for component in ("front", "admin", "postfix", "dovecot", "rspamd", "clamav", "webmail"):
        resources = values[component]["resources"]
        assert resources["requests"]
        assert resources["limits"]

    for component in ("front", "admin", "postfix", "dovecot", "rspamd", "webmail"):
        assert values[component]["nodeSelector"] == {}


def test_mailu_platform_externalsecrets_reference_openbao():
    certificates = _load_yaml(MAILU_PLATFORM_DIR / "externalsecret-certificates.yaml")
    runtime = _load_yaml(MAILU_PLATFORM_DIR / "externalsecret-runtime.yaml")
    relay = _load_yaml(MAILU_PLATFORM_DIR / "externalsecret-relay.yaml")
    relay_egress = _load_yaml(MAILU_PLATFORM_DIR / "externalsecret-relay-egress.yaml")
    assert certificates["metadata"]["namespace"] == "mailu"
    assert runtime["metadata"]["namespace"] == "mailu"
    assert relay["metadata"]["namespace"] == "mailu"
    assert relay_egress["metadata"]["namespace"] == "netbird"
    assert certificates["spec"]["secretStoreRef"]["name"] == "openbao"
    assert certificates["spec"]["target"]["name"] == "mailu-certificates"
    assert certificates["spec"]["target"]["template"]["type"] == "kubernetes.io/tls"
    assert runtime["spec"]["secretStoreRef"]["name"] == "openbao"
    assert relay["spec"]["secretStoreRef"]["name"] == "openbao"
    assert relay_egress["spec"]["secretStoreRef"]["name"] == "openbao"

    certificate_refs = {
        item["secretKey"]: item["remoteRef"]["key"] for item in certificates["spec"]["data"]
    }
    runtime_refs = {item["secretKey"]: item["remoteRef"]["key"] for item in runtime["spec"]["data"]}
    relay_refs = {item["secretKey"]: item["remoteRef"]["key"] for item in relay["spec"]["data"]}
    relay_egress_refs = {
        item["secretKey"]: item["remoteRef"]["key"] for item in relay_egress["spec"]["data"]
    }
    assert runtime_refs == {
        "secret-key": "twinbox/global/mailu-runtime",
        "api-token": "twinbox/global/mailu-runtime",
        "initial-admin-password": "twinbox/global/mailu-runtime",
    }
    assert certificate_refs == {
        "tls.crt": "twinbox/global/mailu-certificates",
        "tls.key": "twinbox/global/mailu-certificates",
    }
    assert relay_refs == {
        "relay-username": "twinbox/global/mailu-relay",
        "relay-password": "twinbox/global/mailu-relay",
    }
    assert relay_egress_refs == {
        "NB_SETUP_KEY": "twinbox/global/netbird-mailu-relay-egress",
        "NB_MANAGEMENT_URL": "twinbox/global/netbird-mailu-relay-egress",
        "NB_HOSTNAME": "twinbox/global/netbird-mailu-relay-egress",
    }


def test_mailu_ingressroutes_target_mailu_front_only():
    docs = list(
        yaml.safe_load_all((MAILU_PLATFORM_DIR / "ingressroute.yaml").read_text(encoding="utf-8"))
    )
    names = {doc["metadata"]["name"] for doc in docs}
    assert names == {"mailu", "mailu-netbird"}

    for doc in docs:
        routes = doc["spec"]["routes"]
        assert len(routes) == 1

        route = routes[0]
        assert route["kind"] == "Rule"
        assert "Host(`mail.__ZONE_NAME__`)" in route["match"]
        service = route["services"][0]
        assert service["name"] == "mailu-front"
        assert service["port"] == 80
        assert route.get("middlewares") is None


def test_external_dns_allows_mx_records():
    values = _load_yaml(REPO_ROOT / "gitops" / "values" / "external-dns.yaml")
    assert "MX" in values["managedRecordTypes"]
    assert "--managed-record-types=MX" in values["extraArgs"]


def test_netbird_firewall_allows_public_smtp_but_not_relay_port():
    firewall = (REPO_ROOT / "infra" / "opentofu" / "netbird" / "firewall.tf").read_text(
        encoding="utf-8"
    )
    assert 'port       = "25"' in firewall
    assert 'port       = "2525"' not in firewall


def test_mailu_step_and_scripts_are_wired():
    step = _load_yaml(REPO_ROOT / "categories" / "apps" / "steps" / "install-mailu" / "step.yaml")
    assert step["id"] == "install-mailu"
    assert step["runner"]["script"] == "categories/apps/steps/install-mailu/run.sh"
    assert step["dashy"]["items"][0]["url_template"] == "https://mail.__ZONE_NAME__/admin"

    apply_script = (REPO_ROOT / "scripts" / "manager" / "apply-argocd-application.sh").read_text(
        encoding="utf-8"
    )
    assert "mailu" in apply_script


def test_mailu_relay_egress_resources_are_wired():
    kustomization = _load_yaml(MAILU_PLATFORM_DIR / "kustomization.yaml")
    assert "externalsecret-certificates.yaml" in kustomization["resources"]
    assert "externalsecret-relay-egress.yaml" in kustomization["resources"]
    assert "relay-egress-config.yaml" in kustomization["resources"]
    assert "relay-egress.yaml" in kustomization["resources"]

    docs = list(yaml.safe_load_all((MAILU_PLATFORM_DIR / "relay-egress.yaml").read_text()))
    service = next(doc for doc in docs if doc["kind"] == "Service")
    deployment = next(doc for doc in docs if doc["kind"] == "Deployment")
    assert service["metadata"]["name"] == "mailu-relay-egress"
    assert service["metadata"]["namespace"] == "netbird"
    assert deployment["metadata"]["namespace"] == "netbird"
    assert service["spec"]["ports"][0]["port"] == 2525

    containers = {
        container["name"]: container
        for container in deployment["spec"]["template"]["spec"]["containers"]
    }
    assert set(containers) == {"netbird", "haproxy", "probe"}
    assert containers["netbird"]["image"] == "netbirdio/netbird:0.72.4"
    assert containers["haproxy"]["image"] == "haproxy:3.0.23-alpine"
    assert containers["probe"]["image"] == "busybox:1.36.1"
    assert containers["haproxy"]["resources"]["requests"]
    assert containers["probe"]["resources"]["limits"]

    config = _load_yaml(MAILU_PLATFORM_DIR / "relay-egress-config.yaml")
    assert config["metadata"]["namespace"] == "netbird"
    assert config["data"]["RELAY_TARGET_PORT"] == "2525"

    appset_text = (REPO_ROOT / "gitops" / "optional-apps" / "mailu.yaml").read_text(
        encoding="utf-8"
    )
    assert "kind: ConfigMap" in appset_text
    assert "name: mailu-relay-egress" in appset_text
    assert "twinbox.io/mailu-relay-host" in appset_text


def test_mailu_single_pvc_workloads_are_pinned_to_storage_node():
    appset_text = (REPO_ROOT / "gitops" / "optional-apps" / "mailu.yaml").read_text(
        encoding="utf-8"
    )

    assert "twinbox.io/mailu-storage-node" in appset_text
    for component in ("front", "admin", "postfix", "dovecot", "rspamd", "webmail"):
        assert f"{component}:\n                nodeSelector:" in appset_text


def test_bastion_postfix_script_has_open_relay_guards():
    script = (REPO_ROOT / "scripts" / "manager" / "configure-bastion-mailu-postfix.sh").read_text(
        encoding="utf-8"
    )
    assert "reject_unauth_destination" in script
    assert "permit_sasl_authenticated,reject" in script
    assert "Refusing to reload Postfix with public mynetworks" in script
    assert "--relay-password" not in script
    assert "--relay-secret-file" in script
    assert "smtpd_tls_security_level=encrypt" in script
    assert "smtpd_tls_auth_only=yes" in script
    assert "Refusing to expose relay listener on public address" in script
    assert 'ufw deny in to any port "$RELAY_LISTEN_PORT" proto tcp' in script


def test_mailu_installer_uses_private_relay_and_pre_dns_preflights():
    script = (REPO_ROOT / "categories" / "apps" / "steps" / "install-mailu" / "run.sh").read_text(
        encoding="utf-8"
    )
    assert ".NETBIRD_RELAY_HOST // .NETBIRD_PRIVATE_IP // empty" in script
    assert ".NETBIRD_IP // empty" not in script.split("mailu_relay_host=", 1)[1].splitlines()[0]
    assert "Refusing to use public bastion IP as Mailu relay host" in script
    assert "netbird-mailu-relay-egress NB_SETUP_KEY" in script
    assert "discover_bastion_netbird_ip" in script
    assert "verify_bastion_mailu_path" in script
    assert "verify_mailu_relay_egress_path" in script
    assert "mailu-relay-egress.netbird.svc.cluster.local" in script
    assert "wait_for_resource netbird externalsecret mailu-relay-egress Ready" in script
    assert "wait_for_resource mailu externalsecret mailu-certificates Ready" in script
    assert "wait_for_resource netbird deployment mailu-relay-egress Available" in script
    assert "choose_mailu_storage_node" in script
    assert "twinbox.io/mailu-storage-node" in script
    assert "generate_mailu_tls_secret_file" in script
    assert "mailu-certificates" in script
    assert "--relay-password" not in script
    assert "--relay-secret-file" in script
    assert script.index('log "Applying Mailu DNS records"') > script.index(
        'verify_bastion_mailu_path "$bastion_ip"'
    )
    assert script.index('log "Applying Mailu DNS records"') > script.index(
        'verify_mailu_relay_egress_path "$mailu_relay_host"'
    )


def test_netbird_network_defines_mailu_relay_egress_group_and_policy():
    main_tf = (REPO_ROOT / "infra" / "opentofu" / "netbird-network" / "main.tf").read_text(
        encoding="utf-8"
    )
    outputs_tf = (REPO_ROOT / "infra" / "opentofu" / "netbird-network" / "outputs.tf").read_text(
        encoding="utf-8"
    )
    configure_script = (
        REPO_ROOT
        / "categories"
        / "talos-cluster"
        / "steps"
        / "configure-netbird-ingress"
        / "run.sh"
    ).read_text(encoding="utf-8")

    assert 'resource "netbird_group" "mailu_relay_egress"' in main_tf
    assert 'resource "netbird_setup_key" "mailu_relay_egress"' in main_tf
    assert "usage_limit            = 0" in main_tf
    assert 'resource "netbird_policy" "mailu_relay_egress_to_bastion_relay"' in main_tf
    assert "sources       = [netbird_group.mailu_relay_egress.id]" in main_tf
    assert "destinations  = [netbird_group.proxy.id]" in main_tf
    assert 'ports         = ["2525"]' in main_tf
    assert 'output "mailu_relay_egress_setup_key"' in outputs_tf
    assert "netbird-mailu-relay-egress" in configure_script


def test_mailu_dkim_parser_uses_structured_record_name_and_value():
    fixture = {
        "records": [
            {
                "name": "customselector._domainkey.example.com.",
                "type": "TXT",
                "value": [
                    "v=DKIM1; k=rsa; p=",
                    "A" * 80,
                ],
            }
        ]
    }
    parser = REPO_ROOT / "scripts" / "manager" / "mailu-dns-export-to-dkim.jq"
    result = subprocess.run(
        ["jq", "-c", "-f", str(parser)],
        input=json.dumps(fixture),
        text=True,
        check=True,
        capture_output=True,
    )
    expected_value = f"v=DKIM1; k=rsa; p={'A' * 80}"
    assert result.stdout.strip() == (
        f'{{"name":"customselector._domainkey.example.com","value":"{expected_value}"' + "}"
    )


def test_mailu_dkim_parser_uses_mailu_dns_dkim_export():
    fixture = {
        "domain": [
            {
                "name": "example.com",
                "dns_dkim": (
                    f'dkim._domainkey.example.com. 600 IN TXT "v=DKIM1; k=rsa; p={"B" * 80}"'
                ),
            }
        ]
    }
    parser = REPO_ROOT / "scripts" / "manager" / "mailu-dns-export-to-dkim.jq"
    result = subprocess.run(
        ["jq", "-c", "-f", str(parser)],
        input=json.dumps(fixture),
        text=True,
        check=True,
        capture_output=True,
    )
    expected_value = f"v=DKIM1; k=rsa; p={'B' * 80}"
    assert result.stdout.strip() == (
        f'{{"name":"dkim._domainkey.example.com","value":"{expected_value}"' + "}"
    )
