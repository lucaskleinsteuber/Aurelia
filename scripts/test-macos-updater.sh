#!/bin/zsh
# Hostless production updater tests: no app host, window, player or personal credentials.
set -euo pipefail
repository_root=${0:A:h:h}
source "$repository_root/scripts/workspace-paths.sh"
/bin/sh "$repository_root/scripts/prune-workspace.sh" || true
run_id="updater-$(date -u +%Y%m%dT%H%M%SZ)-$(uuidgen)"
runtime_root="$HOME/Library/Caches/Tarven/TestRuns/$run_id"
log="$other_root/Logs/$run_id.log"
mkdir -p "$runtime_root/Sources/Tarven" "$runtime_root/Tests/TarvenTests" "$other_root/Logs"
trap 'rm -rf -- "$runtime_root"' EXIT
cat > "$runtime_root/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "TarvenUpdaterTests", platforms: [.macOS("26.0")], targets: [
  .target(name: "Tarven"), .testTarget(name: "TarvenTests", dependencies: ["Tarven"]),
])
SWIFT
for name in AppUpdateLogic AppUpdateDownload AppUpdateSignature; do
  cp "$repository_root/clients/macos/Tarven/Updates/$name.swift" "$runtime_root/Sources/Tarven/"
done
cp "$repository_root/clients/macos/UpdateHandoff/AppEdition.swift" "$runtime_root/Sources/Tarven/"
cp "$repository_root/clients/macos/TarvenTests/AppUpdateLogicTests.swift" "$repository_root/clients/macos/TarvenTests/UpdateSigningFixture.swift" "$runtime_root/Tests/TarvenTests/"
DEVELOPER_DIR="$developer_dir" swift test --package-path "$runtime_root" -Xswiftc -warnings-as-errors 2>&1 | tee "$log"
