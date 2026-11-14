"""Regression tests for spreading replicated platform components across nodes.

A mass pod reschedule (for example after rebooting the cluster VMs) used to pile
every replica of the Longhorn CSI controllers and the CNPG poolers onto a single
small worker node, which saturated it and broke probes cluster-wide.
"""

from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[1]
LONGHORN_VALUES = REPO_ROOT / "gitops" / "values" / "longhorn.yaml"
DATABASES_DIR = REPO_ROOT / "gitops" / "databases"


def _pooler_documents():
    for path in sorted(DATABASES_DIR.glob("*/pooler*.yaml")):
        for document in yaml.safe_load_all(path.read_text(encoding="utf-8")):
            if document and document.get("kind") == "Pooler":
                yield path, document


def test_longhorn_csi_controllers_use_hard_anti_affinity():
    values = yaml.safe_load(LONGHORN_VALUES.read_text(encoding="utf-8"))

    assert values["csi"]["podAntiAffinityPreset"] == "hard"


def test_netbird_routers_have_reserved_resources_and_separate_nodes():
    deployment = yaml.safe_load(
        (REPO_ROOT / "gitops/platform-apps/netbird-routing-peers/deployment.yaml").read_text()
    )
    spec = deployment["spec"]["template"]["spec"]
    terms = spec["affinity"]["podAntiAffinity"]["requiredDuringSchedulingIgnoredDuringExecution"]
    assert terms == [
        {
            "labelSelector": {"matchLabels": deployment["spec"]["selector"]["matchLabels"]},
            "topologyKey": "kubernetes.io/hostname",
        }
    ]
    resources = spec["containers"][0]["resources"]
    assert resources["requests"]["cpu"] == "100m"
    assert resources["requests"]["memory"] == "128Mi"
    assert resources["limits"]["memory"] == "512Mi"


def test_cnpg_poolers_spread_instances_across_nodes():
    poolers = list(_pooler_documents())

    assert poolers, "expected at least one Pooler manifest under gitops/databases"

    for path, pooler in poolers:
        name = pooler["metadata"]["name"]
        template_spec = pooler["spec"]["template"]["spec"]
        constraints = template_spec["topologySpreadConstraints"]

        # The CRD validates the template as a full PodSpec, which requires a
        # container list. The operator keeps its own pgbouncer container and
        # only merges the extra fields.
        assert template_spec["containers"] == [{"name": "pgbouncer"}], (
            f"{path} must declare the pgbouncer container the CRD requires"
        )

        assert constraints == [
            {
                "maxSkew": 1,
                "topologyKey": "kubernetes.io/hostname",
                "whenUnsatisfiable": "ScheduleAnyway",
                "labelSelector": {"matchLabels": {"cnpg.io/poolerName": name}},
            }
        ], f"{path} must spread {name} across nodes"
