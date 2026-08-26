"""Tests for Mailu GitOps manifests and installer contracts."""

import json
import pathlib
import re
import subprocess

import yaml

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
MAILU_PLATFORM_DIR = REPO_ROOT / "gitops" / "platform-apps" / "mailu"
PINNED_DEFAULTS = REPO_ROOT / "config" / "pinned-defaults.sh"


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
    assert re.fullmatch(r"\d+\.\d+\.\d+", helm_source["targetRevision"])
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
    assert values["ingress"]["tlsFlavorOverride"] == "mail"
    assert values["front"]["hostPort"]["enabled"] is False
    assert values["front"]["externalService"]["enabled"] is False

    front_extra_env = {item["name"]: item["value"] for item in values["front"]["extraEnvVars"]}
    assert front_extra_env["PORTS"] == "25,80,443,465,587,993,995,4190"
    assert values["front"]["podAnnotations"]["twinbox.io/mailu-front-config-revision"] == "1"
    assert values["authRequireTokens"] is True
    assert values["api"]["enabled"] is True
    assert values["api"]["existingSecret"] == "mailu-runtime"
    assert values["externalRelay"]["existingSecret"] == "mailu-relay"
    assert values["persistence"]["storageClass"] == "longhorn-single"
    assert values["persistence"]["single_pvc"] is True
    assert values["persistence"]["accessModes"] == ["ReadWriteOnce"]
    assert values["tika"]["enabled"] is False

    assert values["proxyAuth"]["create"] == "true"
    assert values["proxyAuth"]["header"] == "X-authentik-email"
    assert values["proxyAuth"]["whitelist"] == "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
    assert values["sessionTimeout"] == 43200

    for component in ("front", "admin", "postfix", "dovecot", "rspamd", "clamav", "webmail"):
        resources = values[component]["resources"]
        assert resources["requests"]
        assert resources["limits"]

    for component in ("front", "admin", "postfix", "dovecot", "rspamd", "webmail"):
        assert values[component]["nodeSelector"] == {}


def test_mailu_postfix_greets_with_distinct_hostname_to_avoid_loop_detection():
    appset = _load_yaml(REPO_ROOT / "gitops" / "optional-apps" / "mailu.yaml")
    values = _load_yaml(REPO_ROOT / "gitops" / "values" / "mailu.yaml")
    helm_values = appset["spec"]["template"]["spec"]["sources"][0]["helm"]["values"]

    hostnames = re.search(r"hostnames:\n(  - .+\n)+", helm_values)
    assert hostnames, "hostnames block not found"
    hosts = re.findall(r'^  - "([^"]+)"', hostnames.group(0), re.MULTILINE)
    assert len(hosts) >= 2
    assert hosts[0].startswith("mailu.{{")
    assert hosts[0] == hosts[1].replace("mail.{{", "mailu.{{")
    assert "smtpd_banner" not in values.get("postfix", {}).get("overrides", {}).get(
        "postfix.cf", ""
    )


def test_mailu_admin_waits_for_redis_before_boot():
    values = _load_yaml(REPO_ROOT / "gitops" / "values" / "mailu.yaml")
    init_containers = values["admin"]["initContainers"]
    assert any(container["name"] == "wait-for-redis" for container in init_containers)
    wait = next(c for c in init_containers if c["name"] == "wait-for-redis")
    assert wait["image"] == "busybox:1.38.0"
    assert wait["command"] == ["/bin/sh", "-c"]
    raw_args = " ".join(wait["args"])
    assert 'include "mailu.redis.serviceFqdn"' in raw_args
    assert 'include "mailu.redis.port"' in raw_args
    assert "nc -z -w 3" in raw_args
    assert "until" in raw_args


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
    kustomization = _load_yaml(MAILU_PLATFORM_DIR / "kustomization.yaml")
    ingressroute_docs = [d for d in docs if d.get("kind") == "IngressRoute"]
    names = {doc["metadata"]["name"] for doc in ingressroute_docs}
    assert names == {"mailu", "mailu-netbird"}
    assert "netbird-forwarded-headers-middleware.yaml" in kustomization["resources"]

    for doc in ingressroute_docs:
        routes = doc["spec"]["routes"]
        assert len(routes) == 1

        route = routes[0]
        assert route["kind"] == "Rule"
        assert "Host(`mail.__ZONE_NAME__`)" in route["match"]
        service = route["services"][0]
        assert service["name"] == "mailu-front"
        assert service["port"] == 80
        if doc["metadata"]["name"] == "mailu-netbird":
            assert route["middlewares"] == [
                {"name": "mailu-netbird-forwarded-headers"},
                {"name": "authentik-forwardauth"},
            ]
        else:
            assert route["middlewares"] == [{"name": "authentik-forwardauth"}]

    middleware = _load_yaml(MAILU_PLATFORM_DIR / "netbird-forwarded-headers-middleware.yaml")
    assert middleware["metadata"]["name"] == "mailu-netbird-forwarded-headers"
    headers = middleware["spec"]["headers"]["customRequestHeaders"]
    assert headers["X-Forwarded-Proto"] == "https"
    assert headers["X-Forwarded-Port"] == "443"


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
    assert "sets PTR/rDNS automatically only for Hetzner bastions" in step["side_help"]
    assert any(input_item["id"] == "confirm_manual_rdns" for input_item in step["inputs"])

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
    pinned_defaults = PINNED_DEFAULTS.read_text(encoding="utf-8")
    pinned_match = re.search(r"^PINNED_NETBIRD_VERSION=(\S+)$", pinned_defaults, re.M)
    assert pinned_match
    assert containers["netbird"]["image"] == f"netbirdio/netbird:{pinned_match.group(1)}"
    assert re.fullmatch(r"haproxy:\d+\.\d+\.\d+-alpine", containers["haproxy"]["image"])
    assert containers["probe"]["image"] == "busybox:1.38.0"
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
    assert "--bastion-ssh-host" in script
    assert "--bastion-ssh-port" in script
    assert "--bastion-ssh-user" in script
    assert "--client-imaps-port" in script
    assert "--client-submission-port" in script
    assert "${BASTION_SSH_USER}@${BASTION_SSH_HOST}" in script
    assert "smtpd_tls_security_level=encrypt" in script
    assert "smtpd_tls_auth_only=yes" in script
    assert "smtpd_sasl_local_domain = ${MAIL_HOSTNAME}" in script
    assert 'postconf -e "myhostname = ${MAIL_HOSTNAME}"' in script
    assert "Refusing to expose relay listener on public address" in script
    assert (
        "socat TCP-LISTEN:${client_port},fork,reuseaddr TCP:${MAILU_FRONT_ADDRESS}:${client_port}"
        in script
    )
    assert 'ufw allow "$CLIENT_IMAPS_PORT"/tcp' in script
    assert 'ufw allow "$CLIENT_SUBMISSION_PORT"/tcp' in script
    assert 'ufw deny in to any port "$RELAY_LISTEN_PORT" proto tcp' in script


def test_mailu_installer_uses_private_relay_and_pre_dns_preflights():
    script = (REPO_ROOT / "categories" / "apps" / "steps" / "install-mailu" / "run.sh").read_text(
        encoding="utf-8"
    )
    assert "NETBIRD_RELAY_HOST" in script.split("mailu_relay_host=", 1)[1].splitlines()[0]
    assert "NETBIRD_PRIVATE_IP" in script
    assert "awk" in script and "match" in script
    assert "HCLOUD_TOKEN // empty" in script
    assert "BASTION_PUBLIC_IPV4 // .NETBIRD_IP" in script
    assert "BASTION_SSH_HOST // .NETBIRD_IP" in script
    assert "confirm_manual_rdns" in script
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
    assert "ensure_mailu_admin_initialized" in script
    assert "flask db upgrade" in script
    assert "--mode ifmissing" in script
    assert "internal/rspamd/local_domains" in script
    assert "http://127.0.0.1:8080/api/v1" in script
    assert "https://mail.${mail_domain}/api/v1" not in script
    assert 'env MAILU_API_TOKEN="$api_token"' in script
    assert script.index("ensure_mailu_admin_initialized") < script.index(
        'wait_for_selector mailu deployment "app.kubernetes.io/instance=mailu" Available'
    )
    assert "choose_mailu_storage_node" in script
    assert "twinbox.io/mailu-storage-node" in script
    assert "write_mailu_tls_secret_file_from_bastion" in script
    assert "/opt/netbird/certs/wildcard/${public_zone_name}.crt" in script
    assert "/opt/netbird/certs/wildcard/${public_zone_name}.key" in script
    assert "</dev/null >\"$cert_file\"" in script
    assert "</dev/null >\"$key_file\"" in script
    assert "-checkhost \"$mail_hostname\"" in script
    assert script.index('log "Copying the NetBird wildcard TLS certificate for Mailu"') > script.index(
        'ssh_key_file="$(write_bastion_ssh_key'
    )
    assert "mailu-certificates" in script
    assert "ensure-hetzner-rdns.py" in script
    assert '--server-name "$server_name"' in script
    assert '--fallback-server-name "$legacy_server_name"' in script
    assert 'log "Configuring Hetzner PTR/rDNS for ${mail_hostname}"' in script
    assert 'log "PTR/rDNS configured: ${bastion_ip} -> ${mail_hostname}"' in script
    assert 'rdns_status="manual-required"' in script
    assert "Mailu installed. PTR/rDNS configured:" in script
    assert "Create/verify PTR" in script
    assert "--relay-password" not in script
    assert "--relay-secret-file" in script
    assert "--client-imaps-port 993" in script
    assert "--client-submission-port 587" in script
    assert '"SSL/TLS"' in script
    assert '"STARTTLS"' in script
    manual_rdns_gate = (
        "Mailu on a non-Hetzner or non-automated bastion requires confirm_manual_rdns=true"
    )
    assert script.index(manual_rdns_gate) < script.index('ssh_key_file="$(write_bastion_ssh_key')
    assert script.index(manual_rdns_gate) < script.index('log "Applying Mailu Argo CD application"')
    assert script.index(manual_rdns_gate) < script.index('log "Configuring bastion Postfix edge"')
    assert script.index('log "Applying Mailu DNS records"') > script.index(
        'verify_bastion_mailu_path "$bastion_ssh_host"'
    )
    assert script.index('log "Applying Mailu DNS records"') > script.index(
        'verify_mailu_relay_egress_path "$mailu_relay_host"'
    )
    assert script.index('log "Applying Mailu DNS records"') > script.index("confirm_manual_rdns")
    assert script.index("ensure-hetzner-rdns.py") > script.index(
        'apply_mail_dns_records "$mail_domain"'
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


def test_mailu_installer_chooses_storage_node_by_capacity_and_disk():
    script = (REPO_ROOT / "categories" / "apps" / "steps" / "install-mailu" / "run.sh").read_text(
        encoding="utf-8"
    )

    # Must-fit budget names are wired into the chooser.
    assert "MAILU_PINNED_POD_SLOTS:-8" in script
    assert "MAILU_PINNED_CPU_MILLI:-1000" in script
    assert "MAILU_PINNED_MEM_MIB:-2048" in script

    # Selection reads Longhorn storage, with ephemeral-storage fallback.
    assert "nodes.longhorn.io" in script
    assert "storageAvailable" in script
    assert "ephemeral-storage" in script


def test_mailu_installer_rejects_full_nodes_and_fails_loudly():
    script = (REPO_ROOT / "categories" / "apps" / "steps" / "install-mailu" / "run.sh").read_text(
        encoding="utf-8"
    )

    # A node that cannot fit the pinned set is skipped, never silently chosen.
    assert "rejected:" in script
    assert "free_pods" in script
    assert "free_cpu" in script
    assert "free_mem" in script

    # If nothing fits the installer fails with a clear diagnostic.
    assert "No Ready schedulable worker has capacity to host Mailu" in script


def test_mailu_installer_authentik_registration_is_idempotent_and_match_by_name():
    script = (REPO_ROOT / "categories" / "apps" / "steps" / "install-mailu" / "run.sh").read_text(
        encoding="utf-8"
    )

    # Provider/app/policy lookups are GET-first and matched by name, so a partial
    # previous run (provider already created) does not fail the POST with 400.
    assert 'authentik_api_request GET "/providers/proxy/"' in script
    assert 'select(.name == "Mailu")' in script
    assert 'authentik_api_request GET "/core/applications/"' in script
    assert 'select(.slug == "mailu")' in script
    assert 'authentik_api_request GET "/policies/expression/"' in script
    assert 'select(.name == "allow-all-authenticated")' in script
    assert 'authentik_api_request GET "/outposts/instances/"' in script
    assert 'select(.name == "authentik Embedded Outpost")' in script

    # GET lookups must appear before the matching POST create in the script body.
    get_index = script.index('authentik_api_request GET "/providers/proxy/"')
    post_index = script.index('authentik_api_request POST "/providers/proxy/"')
    assert get_index < post_index
    app_get_index = script.index('authentik_api_request GET "/core/applications/"')
    app_post_index = script.index('authentik_api_request POST "/core/applications/"')
    assert app_get_index < app_post_index
