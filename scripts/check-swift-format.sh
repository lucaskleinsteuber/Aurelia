#!/bin/bash
# Checks that every Swift file of the Mac, iPhone and iPad, and Apple TV apps (and the Swift
# scripts and tools) is formatted as swift-format formats it with `.swift-format` at the
# repository root. It uses the swift-format of the pinned Xcode, so every Mac formats alike.
#
#   bash scripts/check-swift-format.sh          reports every difference and fails on one
#   bash scripts/check-swift-format.sh --fix    formats the files in place first, then checks
#
# The Mac, iOS and tvOS test scripts run it first; a run with unformatted code fails before
# anything is built.
set -euo pipefail
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repository_root/scripts/workspace-paths.sh"
cd "$repository_root"
files=()
while IFS= read -r -d '' file; do files+=("$file"); done \
  < <(git ls-files -z --cached --others --exclude-standard -- '*.swift')
[ "${#files[@]}" -gt 0 ] || { echo "No Swift files found." >&2; exit 1; }
swift_format() { DEVELOPER_DIR="$developer_dir" xcrun swift-format "$@"; }
if [ "${1:-}" = --fix ]; then
  swift_format format --in-place --parallel --configuration .swift-format "${files[@]}"
elif [ "$#" -gt 0 ]; then
  echo "Usage: check-swift-format.sh [--fix]" >&2
  exit 1
fi
if ! swift_format lint --strict --parallel --configuration .swift-format "${files[@]}"; then
  echo "Swift formatting differs. Run: bash scripts/check-swift-format.sh --fix" >&2
  exit 1
fi
echo "Swift format: ${#files[@]} files checked."
