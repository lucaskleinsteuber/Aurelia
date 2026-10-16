#!/bin/zsh
set -euo pipefail

repository_root=${0:A:h:h}
source "$repository_root/scripts/workspace-paths.sh"
runtime='com.apple.CoreSimulator.SimRuntime.tvOS-26-0'
device_type='com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-1080p'
if ! xcrun simctl list runtimes --json | python3 -c 'import json,sys;sys.exit(0 if any(r["identifier"] == sys.argv[1] and r.get("isAvailable") for r in json.load(sys.stdin)["runtimes"]) else 1)' "$runtime"; then
  print -u2 'Install the tvOS 26.0 Simulator with Xcode Components before running TV UI tests.'
  exit 1
fi
run_id="tv-ui-$(date -u +%Y%m%dT%H%M%SZ)-$(uuidgen | tr '[:upper:]' '[:lower:]')"
run_root="$HOME/Library/Caches/Aurelia/TestRuns/$run_id"
result="$other_root/Test Results/AureliaTV-UI-$run_id.xcresult"
log="$other_root/Logs/AureliaTV-UI-$run_id.log"
mkdir -p "$run_root" "$other_root/Test Results" "$other_root/Logs"
simulator=''
finish() {
  local exit_code=$?
  set +e
  if [[ -n "$simulator" ]]; then
    xcrun simctl shutdown "$simulator" >/dev/null 2>&1
    xcrun simctl delete "$simulator" >/dev/null 2>&1
  fi
  rm -rf "$run_root"
  exit "$exit_code"
}
trap finish EXIT
dependency_root=${TVVLCKIT_ROOT:-"$repository_root/clients/tvos/Dependencies"}
TVVLCKIT_ROOT="$dependency_root" "$repository_root/scripts/prepare-tvvlckit.sh"
simulator=$(xcrun simctl create "Aurelia UI Tests $run_id" "$device_type" "$runtime")
xcrun simctl boot "$simulator"
xcrun simctl bootstatus "$simulator" -b
arguments=(
  -project "$repository_root/clients/tvos/AureliaTV.xcodeproj"
  -scheme AureliaTVUITests -configuration Debug -sdk appletvsimulator
  -destination "platform=tvOS Simulator,id=$simulator"
  -derivedDataPath "$run_root/DerivedData" -resultBundlePath "$result"
  -collect-test-diagnostics never -enableCodeCoverage NO -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1
  "TVVLCKIT_ROOT=$dependency_root"
  CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES
)
if [[ -n "${AURELIA_TV_UI_TEST_FILTER:-}" ]]; then
  arguments+=("-only-testing:AureliaTVUITests/$AURELIA_TV_UI_TEST_FILTER")
fi
# The dedicated UI scheme always selects the Debug-only synthetic environment.
# Its player runs the production control logic with a simulated engine and relay.
DEVELOPER_DIR="$developer_dir" xcodebuild "${arguments[@]}" test 2>&1 | tee "$log"
print "TV UI results: $result"
print "TV UI log: $log"
