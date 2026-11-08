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

# PID zero is rejected before mounting or touching any installed application. The real
# --no-relaunch path must return failure after consuming its own synthetic download.
xcrun swiftc -warnings-as-errors -swift-version 6 \
  "$repository_root/clients/macos/AureliaServerHost/UpdateInstallation.swift" \
  "$repository_root/clients/macos/AureliaServerHost/UpdateInstaller.swift" \
  "$repository_root/clients/macos/UpdateHandoff/MacUpdateInstallRequest.swift" \
  "$repository_root/clients/macos/UpdateHandoff/AppEdition.swift" \
  "$repository_root/scripts/tests/UpdateInstallerDiagnostic.swift" \
  -o "$run_root/installer-diagnostic"
diagnostic_directory="$run_root/Updates/$(uuidgen)"
mkdir -p "$diagnostic_directory"
diagnostic_image="$diagnostic_directory/synthetic.dmg"
printf '%s\n' 'synthetic image, never mounted' > "$diagnostic_image"
diagnostic_result=0
"$run_root/installer-diagnostic" --install-update "$diagnostic_image" 101 0 --no-relaunch \
  >"$run_root/diagnostic.log" 2>&1 || diagnostic_result=$?
if [ "$diagnostic_result" -ne 1 ] || [ -e "$diagnostic_directory" ]; then
  echo "Diagnostic update failure did not exit safely and clean its UUID download." >&2
  exit 1
fi
echo "Passed diagnostic failure exit cleanup; 24 total installer scenarios, no apps launched or installed."
xcrun swiftc -warnings-as-errors -swift-version 6 \
  "$repository_root/clients/macos/UpdateHandoff/MacUpdateInstallRequest.swift" \
  "$repository_root/clients/macos/UpdateHandoff/AppEdition.swift" \
  "$repository_root/scripts/tests/UpdateHandoffTests.swift" -o "$run_root/handoff-tests"
"$run_root/handoff-tests" "$run_root"
