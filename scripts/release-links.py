#!/usr/bin/env python3
"""Render the compact product links appended to each release description."""
import argparse
import json
from pathlib import Path
import re

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("repository")
parser.add_argument("--candidate", nargs=4, metavar=("PRODUCT", "VERSION", "BUILD", "TAG"))
args = parser.parse_args()
if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository):
    parser.error("Expected a GitHub repository in owner/name form.")

manifest = Path(__file__).resolve().parent.parent / "docs" / "RELEASE_VERSIONS.json"
products = json.loads(manifest.read_text())
if args.candidate:
    product, version, build, tag = args.candidate
    row = next((row for row in products if row["product"] == product), None)
    if row is None or "tag" not in row:
        parser.error("Expected a published product for the candidate.")
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
        parser.error("Expected a MAJOR.MINOR.PATCH version.")
    if not build.isdecimal() or int(build) <= row["build"]:
        parser.error(f"{product} needs a build newer than {row['build']}.")
    if tuple(map(int, version.split("."))) <= tuple(map(int, row["version"].split("."))):
        parser.error(f"{product} needs a version newer than {row['version']}.")
    row.update(version=version, build=int(build), tag=tag)

base = f"https://github.com/{args.repository}"
print("## Versions and downloads")
print()
for row in products:
    label = f'{row["product"]} {row["version"]} ({row["build"]})'
    if "tag" in row:
        print(f'- [{label}]({base}/releases/tag/{row["tag"]})')
    else:
        print(f'- [{label}]({base}/blob/main/{row["guide"]}) · build from source')
