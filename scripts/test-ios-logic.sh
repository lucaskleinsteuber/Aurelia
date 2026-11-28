#!/bin/zsh
set -euo pipefail

repository_root=${0:A:h:h}
source "$repository_root/scripts/workspace-paths.sh"
# Old builds and test results are removed first; see prune-workspace.sh.
/bin/sh "$repository_root/scripts/prune-workspace.sh" || true
# Unformatted Swift fails here, before anything is built (scripts/check-swift-format.sh).
bash "$repository_root/scripts/check-swift-format.sh"
run_id="ios-logic-$(date -u +%Y%m%dT%H%M%SZ)-$(uuidgen | tr '[:upper:]' '[:lower:]')"
runtime_root="$HOME/Library/Caches/Tarven/TestRuns/$run_id"
derived_data="$runtime_root/DerivedData"
temporary_result="$runtime_root/TarvenIOS-Logic.xcresult"
temporary_log="$runtime_root/xcodebuild.log"
final_result="$other_root/Test Results/TarvenIOS-Logic-$run_id.xcresult"
final_log="$other_root/Logs/TarvenIOS-Logic-$run_id.log"
mkdir -p "$runtime_root" "$other_root/Test Results" "$other_root/Logs"

finish() {
  local exit_code=$?
  set +e
  [[ ! -d "$temporary_result" ]] || ditto "$temporary_result" "$final_result"
  [[ ! -f "$temporary_log" ]] || cp "$temporary_log" "$final_log"
  rm -rf "$runtime_root"
  exit "$exit_code"
}
trap finish EXIT

DEVELOPER_DIR="$developer_dir" xcodebuild \
  -project "$repository_root/clients/ios/TarvenIOS.xcodeproj" \
  -scheme TarvenIOSLogicTests -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$temporary_result" \
  -enableCodeCoverage NO -parallel-testing-enabled NO \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES \
  test 2>&1 | tee "$temporary_log"
print "iOS Logic test results: $final_result"
print "iOS Logic test log: $final_log"
