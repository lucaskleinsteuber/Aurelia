#!/bin/sh
# Headless tests of the production installer transaction. No application is launched.
set -eu
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repository_root/scripts/workspace-paths.sh"
/bin/sh "$repository_root/scripts/prune-workspace.sh"
mkdir -p "$HOME/Library/Caches/Aurelia/TestRuns"
run_root=$(mktemp -d "$HOME/Library/Caches/Aurelia/TestRuns/installer.XXXXXX")
trap 'rm -rf "$run_root"' EXIT HUP INT TERM
xcrun swiftc -warnings-as-errors -swift-version 6 \
  "$repository_root/clients/macos/AureliaServerHost/UpdateInstallation.swift" \
  "$repository_root/scripts/tests/UpdateInstallationTests.swift" \
  -o "$run_root/installer-tests"
"$run_root/installer-tests" "$run_root"
