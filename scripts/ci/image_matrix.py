#!/usr/bin/env python3
"""One image inventory and selection policy for verification and publishing."""

import argparse
import json
import os
import re
from pathlib import Path

IMAGE_SPECS = (
    (
        "manager_api",
        "twinbox-manager-api",
        "twinbox-manager-api",
        ".",
        "./manager-api/Dockerfile",
        "standard",
        True,
    ),
    (
        "manager_worker",
        "twinbox-manager-worker",
        "twinbox-manager-worker",
        ".",
        "./manager-worker/Dockerfile",
        "standard",
        True,
    ),
    (
        "manager_web",
        "twinbox-manager-web",
        "twinbox-manager-web",
        ".",
        "./manager-web/Dockerfile",
        "standard",
        False,
    ),
    (
        "portal",
        "twinbox-portal",
        "twinbox-portal",
        "./portal",
        "./portal/Dockerfile",
        "full-sha",
        True,
    ),
    (
        "twinbox_agents",
        "twinbox-agents",
        "twinbox-agents",
        "./twinbox-agents",
        "./twinbox-agents/Dockerfile",
        "full-sha",
        True,
    ),
    (
        "jitsi_openid",
        "twinbox-jitsi-openid",
        "twinbox-manager-worker",
        "./images/jitsi-openid",
        "./images/jitsi-openid/Dockerfile",
        "jitsi",
        False,
    ),
    (
        "twinbox_dev_workspace",
        "twinbox-dev-workspace",
        "twinbox-dev-workspace",
        "./images/twinbox-dev-workspace",
        "./images/twinbox-dev-workspace/Dockerfile",
        "workspace",
        False,
    ),
)


def image_catalog(sha: str) -> list[dict]:
    images = []
    for key, name, package, context, dockerfile, tag_kind, node_runtime in IMAGE_SPECS:
        if tag_kind == "jitsi":
            tags = [
                "type=raw,value=jitsi-openid-latest,enable={{is_default_branch}}",
                "type=ref,event=tag,prefix=jitsi-openid-",
                "type=sha,prefix=jitsi-openid-sha-",
            ]
            published_tag = "jitsi-openid-latest"
        else:
            tags = ["type=raw,value=latest,enable={{is_default_branch}}"]
            if tag_kind == "full-sha":
                tags.append(f"type=raw,value=sha-{sha},enable={{{{is_default_branch}}}}")
            if tag_kind != "workspace":
                tags.append("type=ref,event=tag")
            tags.append("type=sha")
            published_tag = "latest"
        images.append(
            {
                "filter_key": key,
                "image_name": name,
                "package_name": package,
                "context": context,
                "dockerfile": dockerfile,
                "tags": "\n".join(tags),
                "published_ref": f"ghcr.io/harrywesterman/{package}:{published_tag}",
                "node_runtime": node_runtime,
            }
        )
    return images


def select_images(images: list[dict], event: str, ref: str, filters: dict[str, bool]) -> list[dict]:
    force_all = (
        event == "workflow_dispatch"
        or ref.startswith("refs/tags/v")
        or (event == "push" and ref == "refs/heads/main")
        or filters.get("force_all", False)
    )
    return (
        images
        if force_all
        else [image for image in images if filters.get(image["filter_key"], False)]
    )


def workflow_outputs(sha: str, event: str, ref: str, filters: dict[str, bool]) -> dict[str, str]:
    images = image_catalog(sha)
    selected = select_images(images, event, ref, filters)
    selected_names = {image["image_name"] for image in selected}
    verify_images = list(selected)
    if event == "pull_request" and (
        filters.get("headwind_node", False) or filters.get("force_all", False)
    ):
        values = Path("gitops/platform-apps/headwind-mdm/values.yaml").read_text(encoding="utf-8")
        match = re.search(r"^\s+image:\s*(node:[^\s]+)\s*$", values, re.MULTILINE)
        if match is None:
            raise ValueError("Headwind bootstrap Node image not found")
        verify_images.append(
            {
                "image_name": "headwind-bootstrap-node",
                "dockerfile": "",
                "context": "",
                "source_ref": match.group(1),
                "node_runtime": True,
            }
        )
    return {
        "matrix": json.dumps({"include": selected}, separators=(",", ":")),
        "should_publish": str(bool(selected)).lower(),
        "verify_matrix": json.dumps({"include": verify_images}, separators=(",", ":")),
        "should_verify": str(bool(verify_images)).lower(),
        "selected_images": json.dumps(
            [image["image_name"] for image in selected], separators=(",", ":")
        ),
        "skipped_images": json.dumps(
            [image["image_name"] for image in images if image["image_name"] not in selected_names],
            separators=(",", ":"),
        ),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--published", action="store_true")
    args = parser.parse_args()
    output_path = Path(os.environ["GITHUB_OUTPUT"])
    if args.published:
        images = image_catalog(os.environ.get("GITHUB_SHA", ""))
        matrix = [
            {"image_name": image["image_name"], "published_ref": image["published_ref"]}
            for image in images
        ]
        with output_path.open("a", encoding="utf-8") as output:
            output.write(f"matrix={json.dumps({'include': matrix}, separators=(',', ':'))}\n")
        return
    filters = {
        key: os.environ.get(f"{key.upper()}_CHANGED", "false") == "true" for key, *_ in IMAGE_SPECS
    }
    filters["force_all"] = os.environ.get("FORCE_ALL", "false") == "true"
    filters["headwind_node"] = os.environ.get("HEADWIND_NODE_CHANGED", "false") == "true"
    outputs = workflow_outputs(
        os.environ["GITHUB_SHA"], os.environ["EVENT_NAME"], os.environ["GITHUB_REF"], filters
    )
    with output_path.open("a", encoding="utf-8") as output:
        for key, value in outputs.items():
            output.write(f"{key}={value}\n")


if __name__ == "__main__":
    main()
