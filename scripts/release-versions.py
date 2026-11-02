#!/usr/bin/env python3
"""Render verified product versions; publishers override only their verified candidate."""
import argparse
import json
from pathlib import Path
import re

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--product", choices=("mac", "linux"))
parser.add_argument("--version")
parser.add_argument("--build", type=int)
parser.add_argument("--readme", action="store_true")
args = parser.parse_args()
if any((args.product, args.version, args.build)) and not all((args.product, args.version, args.build)):
    parser.error("A candidate needs --product, --version and --build together.")
rows = json.loads((root / "docs/RELEASE_VERSIONS.json").read_text())
if args.product:
    row = rows[0 if args.product == "mac" else 1]
    row.update(version=args.version, build=args.build,
               tag=("linux-app-" if args.product == "linux" else "") + f"{args.version}-{args.build}")
lines = ["| Product | Version | Build | Download / availability |", "| --- | --- | --- | --- |"]
for row in rows:
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", row["version"]) or row["build"] < 1:
        raise ValueError("Invalid verified product version")
    if "tag" in row:
        availability = f'[Downloads](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/{row["tag"]})'
    else:
        availability = f'Development installation; [build from source](https://github.com/lucaskleinsteuber/Aurelia/blob/main/{row["guide"]})'
    lines.append(f'| **{row["product"]}** | {row["version"]} | {row["build"]} | {availability} |')
table = "\n".join(lines)
if args.readme:
    if args.product:
        parser.error("Do not put a prepared candidate in the README; update the verified record after delivery.")
    path = root / "README.md"
    text = path.read_text()
    block = f"<!-- release-versions:start -->\n{table}\n<!-- release-versions:end -->"
    if "<!-- release-versions:start -->" in text:
        text = re.sub(r"<!-- release-versions:start -->.*?<!-- release-versions:end -->", block, text, flags=re.S)
    else:
        text = text.replace("## At a glance", "## Current versions\n\n" + block + "\n\nEach app has its own Semantic Versioning counter. Mac and server share one version.\nThe Mac/server channel remains GitHub’s Latest release; Linux Desktop updates independently.\n\n## At a glance", 1)
    path.write_text(text)
else:
    print(table)
