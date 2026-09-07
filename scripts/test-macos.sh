#!/bin/zsh
set -euo pipefail

repository_root=${0:A:h:h}
other_root=${AURELIA_HOME_OTHER_ROOT:-"${repository_root:h}/Aurelia Home Other"}
developer_dir=${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}
runtime_parent="$HOME/Library/Caches/AureliaHome/TestRuns"
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$(uuidgen | tr '[:upper:]' '[:lower:]')"
runtime_root="$runtime_parent/$run_id"
derived_data="$runtime_root/DerivedData"
temporary_result="$runtime_root/AureliaHome.xcresult"
temporary_log="$runtime_root/xcodebuild.log"
result_root="$other_root/Test Results"
log_root="$other_root/Logs"
final_result="$result_root/AureliaHome-macOS-$run_id.xcresult"
final_log="$log_root/AureliaHome-macOS-$run_id.log"

mkdir -p "$runtime_root" "$result_root" "$log_root"

stop_test_hosts() {
  pkill -x AureliaHome 2>/dev/null || true
  pkill -x AureliaHomeUITests-Runner 2>/dev/null || true
}

finish() {
  exit_code=$?
  set +e
  stop_test_hosts
  if [[ -d "$temporary_result" ]]; then
    ditto "$temporary_result" "$final_result"
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
  -project "$repository_root/clients/macos/AureliaHome.xcodeproj" \
  -scheme AureliaHome \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$temporary_result" \
  -enableCodeCoverage NO \
  test 2>&1 | tee "$temporary_log"
