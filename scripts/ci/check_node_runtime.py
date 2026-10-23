#!/usr/bin/env python3
"""Check that a built runtime contains the patched Node version declared in source."""

import argparse
import re
import subprocess
from pathlib import Path

MINIMUM_PATCHED = {24: (24, 22, 1), 26: (26, 12, 1)}


def declared_version(source: Path) -> tuple[int, int, int]:
    text = source.read_text(encoding="utf-8")
    if source.name == "Dockerfile":
        tags = re.findall(r"^FROM node:(\d+\.\d+\.\d+)-alpine(?:\s|$)", text, re.MULTILINE)
        if not tags:
            raise ValueError(f"No full Node patch version in {source}")
        tag = tags[-1]
    else:
        match = re.search(r"^\s+image:\s*node:(\d+\.\d+\.\d+)-alpine\s*$", text, re.MULTILINE)
        if match is None:
            raise ValueError(f"No Headwind Node image in {source}")
        tag = match.group(1)
    return tuple(map(int, tag.split(".")))


def validate_version(declared: tuple[int, int, int], actual: str) -> None:
    expected = MINIMUM_PATCHED.get(declared[0])
    if expected is None or declared < expected:
        raise ValueError(f"Unsupported or vulnerable Node pin: {declared}")
    match = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)", actual.strip())
    if match is None:
        raise ValueError(f"Unexpected Node version output: {actual!r}")
    observed = tuple(map(int, match.groups()))
    if observed != declared:
        raise ValueError(f"Image Node {observed} differs from declared {declared}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", required=True)
    parser.add_argument("--source", type=Path, required=True)
    args = parser.parse_args()
    result = subprocess.run(
        ["docker", "run", "--rm", "--entrypoint", "node", args.image, "--version"],
        check=True,
        text=True,
        capture_output=True,
    )
    declared = declared_version(args.source)
    validate_version(declared, result.stdout)
    print(f"Verified Node {result.stdout.strip()} in {args.image}")


if __name__ == "__main__":
    main()
