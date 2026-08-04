"""Guardrails for public Traefik IngressRoute entrypoints."""

import pathlib

import yaml

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
BASE_DIRS = (
    REPO_ROOT / "gitops" / "platform",
    REPO_ROOT / "gitops" / "platform-apps",
)
APP_DIRS = (
    REPO_ROOT / "gitops" / "apps",
    REPO_ROOT / "gitops" / "optional-apps",
)


def _yaml_docs(path):
    return list(yaml.safe_load_all(path.read_text(encoding="utf-8")))


def _ingressroute_docs():
    for base_dir in BASE_DIRS:
        for path in sorted(base_dir.rglob("*.yaml")):
            # Helm templates are rendered separately; their Go template
            # expressions are intentionally not parseable as raw YAML.
            if "templates" in path.parts:
                continue
            text = path.read_text(encoding="utf-8")
            if "kind: IngressRoute" not in text:
                continue
            for doc in yaml.safe_load_all(text):
                if isinstance(doc, dict) and doc.get("kind") == "IngressRoute":
                    yield path, doc


def _walk_dicts(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from _walk_dicts(child)
    elif isinstance(value, list):
        for child in value:
            yield from _walk_dicts(child)


def _middleware_names(route):
    return [middleware["name"] for middleware in route.get("middlewares") or []]


def test_public_websecure_ingressroutes_have_matching_webnetbird_routes():
    ingressroutes = list(_ingressroute_docs())
    by_namespace_name = {
        (
            doc["metadata"].get("namespace", "default"),
            doc["metadata"]["name"],
        ): (path, doc)
        for path, doc in ingressroutes
    }

    for path, websecure in ingressroutes:
        spec = websecure.get("spec", {})
        if spec.get("entryPoints") != ["websecure"]:
            continue
        if not any("Host(`" in route.get("match", "") for route in spec.get("routes") or []):
            continue

        namespace = websecure["metadata"].get("namespace", "default")
        name = websecure["metadata"]["name"]
        netbird_key = (namespace, f"{name}-netbird")
        assert netbird_key in by_namespace_name, f"{path}: missing {name}-netbird"

        netbird_path, netbird = by_namespace_name[netbird_key]
        netbird_spec = netbird["spec"]
        assert netbird_spec["entryPoints"] == ["webnetbird"], netbird_path
        assert "tls" not in netbird_spec, netbird_path

        websecure_routes = spec["routes"]
        netbird_routes = netbird_spec["routes"]
        assert len(netbird_routes) == len(websecure_routes), netbird_path

        for websecure_route, netbird_route in zip(websecure_routes, netbird_routes, strict=True):
            assert netbird_route["kind"] == websecure_route["kind"], netbird_path
            assert netbird_route["match"] == websecure_route["match"], netbird_path
            assert netbird_route["services"] == websecure_route["services"], netbird_path

            netbird_middlewares = set(_middleware_names(netbird_route))
            assert not {"cloudflarewarp", "crowdsec"} & netbird_middlewares, netbird_path
            assert set(_middleware_names(websecure_route)).issubset(netbird_middlewares), (
                netbird_path
            )


def test_argocd_host_patches_cover_websecure_and_webnetbird_route_names():
    route_names = {doc["metadata"]["name"] for _, doc in _ingressroute_docs()}

    for app_dir in APP_DIRS:
        for path in sorted(app_dir.glob("*.yaml")):
            text = path.read_text(encoding="utf-8")
            if "kind: IngressRoute" not in text or "/spec/routes/0/match" not in text:
                continue

            for doc in _yaml_docs(path):
                for item in _walk_dicts(doc):
                    patches = item.get("patches")
                    if not isinstance(patches, list):
                        continue

                    ingressroute_patches = {}
                    for patch in patches:
                        target = patch.get("target") or {}
                        if target.get("kind") != "IngressRoute":
                            continue
                        patch_body = patch.get("patch", "")
                        if "/spec/routes/0/match" not in patch_body:
                            continue
                        ingressroute_patches[target["name"]] = patch_body.strip()

                    for name, patch_body in ingressroute_patches.items():
                        if name.endswith("-netbird"):
                            continue
                        netbird_name = f"{name}-netbird"
                        if netbird_name not in route_names:
                            continue
                        assert netbird_name in ingressroute_patches, (
                            f"{path}: missing host patch for {netbird_name}"
                        )
                        assert ingressroute_patches[netbird_name] == patch_body, (
                            f"{path}: {netbird_name} host patch differs from {name}"
                        )


def test_authentik_exposes_opencloud_global_oidc_discovery_on_both_entrypoints():
    ingressroutes = {doc["metadata"]["name"]: doc for _, doc in _ingressroute_docs()}

    for name, entrypoint in [
        ("authentik-opencloud-oidc-discovery", "websecure"),
        ("authentik-opencloud-oidc-discovery-netbird", "webnetbird"),
    ]:
        doc = ingressroutes[name]
        assert doc["spec"]["entryPoints"] == [entrypoint]
        route = doc["spec"]["routes"][0]
        assert "Path(`/.well-known/openid-configuration`)" in route["match"]
        assert route["middlewares"] == [{"name": "opencloud-oidc-discovery"}]
        assert route["services"] == [{"kind": "Service", "name": "authentik-server", "port": 80}]

    middleware = (
        REPO_ROOT / "gitops" / "platform" / "authentik" / "opencloud-oidc-discovery-middleware.yaml"
    )
    middleware_doc = yaml.safe_load(middleware.read_text(encoding="utf-8"))
    assert middleware_doc["spec"]["replacePathRegex"] == {
        "regex": r"^/\.well-known/openid-configuration$",
        "replacement": "/application/o/opencloud/.well-known/openid-configuration",
    }
