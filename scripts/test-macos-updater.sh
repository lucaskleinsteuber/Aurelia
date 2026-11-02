#!/bin/zsh
# Hostless production updater tests: no app host, window, player or personal credentials.
set -euo pipefail
repository_root=${0:A:h:h}
source "$repository_root/scripts/workspace-paths.sh"
/bin/sh "$repository_root/scripts/prune-workspace.sh" || true
run_id="updater-$(date -u +%Y%m%dT%H%M%SZ)-$(uuidgen)"
runtime_root="$HOME/Library/Caches/Aurelia/TestRuns/$run_id"
log="$other_root/Logs/$run_id.log"
mkdir -p "$runtime_root/Sources/Aurelia" "$runtime_root/Tests/AureliaTests" "$other_root/Logs"
trap 'rm -rf -- "$runtime_root"' EXIT
cat > "$runtime_root/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "AureliaUpdaterTests", platforms: [.macOS("26.0")], targets: [
  .target(name: "Aurelia"), .testTarget(name: "AureliaTests", dependencies: ["Aurelia"]),
])
SWIFT
for name in AppUpdateLogic AppUpdateDownload; do
  cp "$repository_root/clients/macos/Aurelia/Updates/$name.swift" "$runtime_root/Sources/Aurelia/"
done
cp "$repository_root/clients/macos/AureliaTests/AppUpdateLogicTests.swift" "$runtime_root/Tests/AureliaTests/"
DEVELOPER_DIR="$developer_dir" swift test --package-path "$runtime_root" -Xswiftc -warnings-as-errors 2>&1 | tee "$log"
