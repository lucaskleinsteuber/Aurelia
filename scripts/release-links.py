#!/usr/bin/env python3
"""Render the compact product links appended to each release description."""
import argparse
import json
from pathlib import Path
import re
import subprocess

VERSION_RE = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")
MAC_TAG_RE = re.compile(r"^((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))-([0-9]+)$")


def read_xcconfig_version(path: Path) -> tuple[str, int] | None:
    if not path.is_file():
        return None
    text = path.read_text()
    version_match = re.search(r"^MARKETING_VERSION\s*=\s*(\S+)\s*$", text, re.M)
    build_match = re.search(r"^CURRENT_PROJECT_VERSION\s*=\s*([0-9]+)\s*$", text, re.M)
    if not version_match or not build_match:
        return None
    version = version_match.group(1)
    if not VERSION_RE.fullmatch(version):
        return None
    return version, int(build_match.group(1))


def newest_mac_tag(repo_root: Path) -> tuple[str, int, str] | None:
    result = subprocess.run(
        ["git", "-C", str(repo_root), "tag", "-l"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return None
    best: tuple[int, str, str] | None = None
    for tag in result.stdout.splitlines():
        match = MAC_TAG_RE.fullmatch(tag.strip())
        if not match:
            continue
        version, build_str = match.group(1), match.group(2)
        build = int(build_str)
        if best is None or build > best[0]:
            best = (build, version, tag.strip())
    return (best[1], best[0], best[2]) if best else None


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("repository")
parser.add_argument("--candidate", nargs=4, metavar=("PRODUCT", "VERSION", "BUILD", "TAG"))
args = parser.parse_args()
if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository):
    parser.error("Expected a GitHub repository in owner/name form.")

repo_root = Path(__file__).resolve().parent.parent
manifest = repo_root / "docs" / "RELEASE_VERSIONS.json"
products = json.loads(manifest.read_text())

# Refresh build-from-source products from their project files and Mac from its newest beta tag
# so release notes never stay frozen on outdated manifest rows (audit REL-REPO-005).
source_configs = {
    "Apple TV": repo_root / "clients" / "tvos" / "Configuration" / "BuildNumber.xcconfig",
    "iPhone & iPad": repo_root / "clients" / "ios" / "Configuration" / "BuildNumber.xcconfig",
}
for row in products:
    product_name = row["product"]
    if product_name in source_configs:
        current = read_xcconfig_version(source_configs[product_name])
        if current and current[1] >= row["build"]:
            row.update(version=current[0], build=current[1])
    elif product_name == "Mac":
        mac_beta = newest_mac_tag(repo_root)
        if mac_beta and mac_beta[1] > row["build"]:
            row.update(version=mac_beta[0], build=mac_beta[1], tag=mac_beta[2], beta_only=True)

if args.candidate:
    product, version, build, tag = args.candidate
    row = next((row for row in products if row["product"] == product), None)
    if row is None or "tag" not in row:
        parser.error("Expected a published product for the candidate.")
    if not VERSION_RE.fullmatch(version):
        parser.error("Expected a MAJOR.MINOR.PATCH version.")
    if not build.isdecimal():
        parser.error("Expected a numeric build.")
    build_number = int(build)
    # The exact release being published may already be recorded; any other release must have a
    # strictly higher build number (audit REL-REPO-009).
    already_recorded = (
        version == row["version"] and build_number == row["build"] and tag == row["tag"]
    )
    if not already_recorded and build_number <= row["build"]:
        parser.error(f"{product} needs a build newer than {row['build']}.")
    if tuple(map(int, version.split("."))) < tuple(map(int, row["version"].split("."))):
        parser.error(f"{product} needs at least version {row['version']}.")
    row.update(version=version, build=build_number, tag=tag)
    if product == "Mac":
        row["beta_only"] = True

base = f"https://github.com/{args.repository}"
print("## Versions and downloads")
print()
for row in products:
    label = f'{row["product"]} {row["version"]} ({row["build"]})'
    if "tag" in row:
        suffix = " · newest beta" if row.get("beta_only") else ""
        print(f'- [{label}]({base}/releases/tag/{row["tag"]}){suffix}')
    else:
        print(f'- [{label}]({base}/blob/main/{row["guide"]}) · build from source')
