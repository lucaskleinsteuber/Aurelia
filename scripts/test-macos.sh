#!/bin/zsh
set -euo pipefail

repository_root=${0:A:h:h}
source "$repository_root/scripts/workspace-paths.sh"
# Old builds and test results are removed first; see prune-workspace.sh.
/bin/sh "$repository_root/scripts/prune-workspace.sh" || true
# Unformatted Swift fails here, before anything is built (scripts/check-swift-format.sh).
bash "$repository_root/scripts/check-swift-format.sh"
runtime_parent="$HOME/Library/Caches/Tarven/TestRuns"
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$(uuidgen | tr '[:upper:]' '[:lower:]')"
runtime_root="$runtime_parent/$run_id"
derived_data="$runtime_root/DerivedData"
temporary_unit_result="$runtime_root/Tarven-Unit.xcresult"
temporary_ui_result="$runtime_root/Tarven-UI.xcresult"
temporary_log="$runtime_root/xcodebuild.log"
result_root="$other_root/Test Results"
log_root="$other_root/Logs"
final_unit_result="$result_root/Tarven-macOS-Unit-$run_id.xcresult"
final_ui_result="$result_root/Tarven-macOS-UI-$run_id.xcresult"
final_log="$log_root/Tarven-macOS-$run_id.log"
unit_test_filter="${TARVEN_UNIT_TEST_FILTER:-TarvenTests}"
unit_test_exclusions=(-skip-testing:TarvenTests/PlaybackFullChainTests)

if [[ "${TARVEN_LOGIC_ONLY:-0}" == "1" ]]; then
  # Keep native engines, decoder/rendering probes and optional live-server credentials out
  # of this explicit logic-only run. Controller/transport tests with injected fakes remain.
  if [[ "$unit_test_filter" != TarvenTests && "$unit_test_filter" != TarvenTests/* ]]; then
    print -u2 "Logic-only runs must select TarvenTests, not a UI test target."
    exit 1
  fi
  for suite in PlaybackEngineReliabilityTests PlaybackStartTests PlayerComfortTests \
    ScrubPreviewTests TarvenIntegrationTests ImportPlanningTests MetadataEditorTests \
    ServerSettingsRenderTests PlayerFullScreenKeyboardTests; do
    unit_test_exclusions+=("-skip-testing:TarvenTests/$suite")
  done
fi

mkdir -p "$runtime_root" "$result_root" "$log_root"

stop_test_hosts() {
  # Never stop the installed app or another task's host. Only this run owns these PIDs.
  local test_pid test_command
  for test_pid in $(pgrep -x Tarven 2>/dev/null || true) $(pgrep -x TarvenUITests-Runner 2>/dev/null || true); do
    test_command=$(ps -p "$test_pid" -o comm= 2>/dev/null || true)
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
  -project "$repository_root/clients/macos/Tarven.xcodeproj" \
  -scheme Tarven \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$derived_data" \
  -enableCodeCoverage NO \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  build-for-testing 2>&1 | tee "$temporary_log"

# XCTest searches the standalone build-products framework before the signed
# copy embedded in the host. XCFramework processing leaves that standalone
# copy unsigned, so use this run's already signed embedded copy for both paths.
# Never re-sign or modify the shared vendor framework or the installed app.
embedded_vlc="$derived_data/Build/Products/Debug/Tarven.app/Contents/Frameworks/VLCKit.framework"
test_vlc="$derived_data/Build/Products/Debug/VLCKit.framework"
if [[ ! -d "$embedded_vlc" || ! -d "$test_vlc" || -L "$test_vlc" ]]; then
  print -u2 "The test host's isolated VLC framework copies are missing or unsafe."
  exit 1
fi
/usr/bin/codesign --verify --strict "$embedded_vlc"
/usr/bin/ditto "$embedded_vlc" "$test_vlc"
/usr/bin/codesign --verify --strict "$test_vlc"

TEST_RUNNER_TARVEN_PLAYBACK_SOAK_SECONDS="${TARVEN_PLAYBACK_SOAK_SECONDS:-15}" \
DEVELOPER_DIR="$developer_dir" xcodebuild \
  -project "$repository_root/clients/macos/Tarven.xcodeproj" \
  -scheme Tarven \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$temporary_unit_result" \
  -enableCodeCoverage NO \
  -parallel-testing-enabled NO \
  -only-testing:"$unit_test_filter" \
  "${unit_test_exclusions[@]}" \
  test-without-building 2>&1 | tee -a "$temporary_log"

stop_test_hosts

if [[ "${TARVEN_SKIP_UI_TESTS:-0}" != "1" && "${TARVEN_LOGIC_ONLY:-0}" != "1" ]]; then
  # TARVEN_UI_TEST_FILTER takes one or more comma-separated test identifiers.
  ui_test_filters=()
  for filter in "${(@s:,:)${TARVEN_UI_TEST_FILTER:-TarvenUITests}}"; do
    ui_test_filters+=("-only-testing:$filter")
  done
  DEVELOPER_DIR="$developer_dir" xcodebuild \
    -project "$repository_root/clients/macos/Tarven.xcodeproj" \
    -scheme Tarven \
    -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath "$derived_data" \
    -resultBundlePath "$temporary_ui_result" \
    -enableCodeCoverage NO \
    -parallel-testing-enabled NO \
    "${ui_test_filters[@]}" \
    test-without-building 2>&1 | tee -a "$temporary_log"
fi
