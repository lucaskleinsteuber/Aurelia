#!/bin/zsh
set -euo pipefail

repository_root=${0:A:h:h}
source "$repository_root/scripts/workspace-paths.sh"
runtime_parent="$HOME/Library/Caches/Aurelia/TestRuns"
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$(uuidgen | tr '[:upper:]' '[:lower:]')"
runtime_root="$runtime_parent/$run_id"
derived_data="$runtime_root/DerivedData"
temporary_unit_result="$runtime_root/Aurelia-Unit.xcresult"
temporary_ui_result="$runtime_root/Aurelia-UI.xcresult"
temporary_log="$runtime_root/xcodebuild.log"
result_root="$other_root/Test Results"
log_root="$other_root/Logs"
final_unit_result="$result_root/Aurelia-macOS-Unit-$run_id.xcresult"
final_ui_result="$result_root/Aurelia-macOS-UI-$run_id.xcresult"
final_log="$log_root/Aurelia-macOS-$run_id.log"

mkdir -p "$runtime_root" "$result_root" "$log_root"

stop_test_hosts() {
  # Never stop the installed app or another task's host. Only this run owns these PIDs.
  local test_pid test_command
  for test_pid in $(pgrep -x Aurelia 2>/dev/null || true) $(pgrep -x AureliaUITests-Runner 2>/dev/null || true); do
    test_command=$(ps -p "$test_pid" -o command= 2>/dev/null || true)
    if [[ "$test_command" == "$runtime_root/"* ]]; then
      kill -TERM "$test_pid" 2>/dev/null || true
    fi
  done
}

finish() {
  exit_code=$?
  set +e
  stop_test_hosts
  if [[ -d "$temporary_unit_result" ]]; then
    ditto "$temporary_unit_result" "$final_unit_result"
  fi
  if [[ -d "$temporary_ui_result" ]]; then
    ditto "$temporary_ui_result" "$final_ui_result"
  fi
  if [[ -f "$temporary_log" ]]; then
    cp "$temporary_log" "$final_log"
  fi
  rm -rf "$runtime_root"
  exit $exit_code
}
trap finish EXIT

stop_test_hosts
"$repository_root/scripts/prepare-vlckit.sh"

DEVELOPER_DIR="$developer_dir" xcodebuild \
  -project "$repository_root/clients/macos/Aurelia.xcodeproj" \
  -scheme Aurelia \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$derived_data" \
  -enableCodeCoverage NO \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  build-for-testing 2>&1 | tee "$temporary_log"

# XCTest searches the standalone build-products framework before the signed
# copy embedded in the host. XCFramework processing leaves that standalone
# copy unsigned, so use this run's already signed embedded copy for both paths.
# Never re-sign or modify the shared vendor framework or the installed app.
embedded_vlc="$derived_data/Build/Products/Debug/Aurelia.app/Contents/Frameworks/VLCKit.framework"
test_vlc="$derived_data/Build/Products/Debug/VLCKit.framework"
if [[ ! -d "$embedded_vlc" || ! -d "$test_vlc" || -L "$test_vlc" ]]; then
  print -u2 "The test host's isolated VLC framework copies are missing or unsafe."
  exit 1
fi
/usr/bin/codesign --verify --strict "$embedded_vlc"
/usr/bin/ditto "$embedded_vlc" "$test_vlc"
/usr/bin/codesign --verify --strict "$test_vlc"

TEST_RUNNER_AURELIA_PLAYBACK_SOAK_SECONDS="${AURELIA_PLAYBACK_SOAK_SECONDS:-15}" \
DEVELOPER_DIR="$developer_dir" xcodebuild \
  -project "$repository_root/clients/macos/Aurelia.xcodeproj" \
  -scheme Aurelia \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$temporary_unit_result" \
  -enableCodeCoverage NO \
  -parallel-testing-enabled NO \
  -only-testing:"${AURELIA_UNIT_TEST_FILTER:-AureliaTests}" \
  -skip-testing:AureliaTests/PlaybackFullChainTests \
  test-without-building 2>&1 | tee -a "$temporary_log"

stop_test_hosts

if [[ "${AURELIA_SKIP_UI_TESTS:-0}" != "1" ]]; then
  DEVELOPER_DIR="$developer_dir" xcodebuild \
    -project "$repository_root/clients/macos/Aurelia.xcodeproj" \
    -scheme Aurelia \
    -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath "$derived_data" \
    -resultBundlePath "$temporary_ui_result" \
    -enableCodeCoverage NO \
    -parallel-testing-enabled NO \
    -only-testing:"${AURELIA_UI_TEST_FILTER:-AureliaUITests}" \
    test-without-building 2>&1 | tee -a "$temporary_log"
fi
