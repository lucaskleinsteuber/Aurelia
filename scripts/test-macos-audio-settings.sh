#!/bin/zsh
# Hostless production audio settings tests: no app host, window, player or personal credentials.
set -euo pipefail
repository_root=${0:A:h:h}
source "$repository_root/scripts/workspace-paths.sh"
/bin/sh "$repository_root/scripts/prune-workspace.sh" || true
run_id="audio-settings-$(date -u +%Y%m%dT%H%M%SZ)-$(uuidgen)"
runtime_root="$HOME/Library/Caches/Tarven/TestRuns/$run_id"
log="$other_root/Logs/$run_id.log"
mkdir -p "$runtime_root/Sources/Tarven" "$runtime_root/Tests/TarvenTests" "$other_root/Logs"
trap 'rm -rf -- "$runtime_root"' EXIT
cat > "$runtime_root/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "TarvenAudioSettingsTests", platforms: [.macOS("26.0")], targets: [
  .target(name: "Tarven"), .testTarget(name: "TarvenTests", dependencies: ["Tarven"]),
])
SWIFT
for name in AudioProcessing PlaybackPreferences SubtitleAppearance; do
  cp "$repository_root/clients/macos/Tarven/Playback/$name.swift" "$runtime_root/Sources/Tarven/"
done
cp "$repository_root/clients/macos/TarvenTests/AudioProcessingTests.swift" "$runtime_root/Tests/TarvenTests/"
DEVELOPER_DIR="$developer_dir" swift test --package-path "$runtime_root" -Xswiftc -warnings-as-errors 2>&1 | tee "$log"
