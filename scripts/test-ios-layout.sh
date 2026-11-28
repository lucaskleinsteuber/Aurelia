#!/bin/zsh
# Runs rendered UIHostingController layout and truncation tests across iPhone, iPad, Slide Over,
# Landscape, and accessibility Dynamic Type viewports in a headless iOS Simulator session.
set -euo pipefail

repository_root=${0:A:h:h}
source "$repository_root/scripts/workspace-paths.sh"
/bin/sh "$repository_root/scripts/prune-workspace.sh" || true
bash "$repository_root/scripts/check-swift-format.sh"

dependency_root=${MOBILEVLCKIT_ROOT:-"$repository_root/clients/ios/Dependencies"}
MOBILEVLCKIT_ROOT="$dependency_root" "$repository_root/scripts/prepare-ios-vlckit.sh"

simulator_id=${TARVEN_IOS_SIMULATOR_ID:-$(
  xcrun simctl list devices available | grep -E "    iPhone .*\([0-9A-F-]{36}\)" | tail -1 \
    | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/'
)}
if [[ -z "$simulator_id" ]]; then
  print -u2 "No available iPhone Simulator found for iOS layout tests."
  exit 1
fi

run_id="ios-layout-$(date -u +%Y%m%dT%H%M%SZ)-$(uuidgen | tr '[:upper:]' '[:lower:]')"
runtime_root="$HOME/Library/Caches/Tarven/TestRuns/$run_id"
derived_data="$runtime_root/DerivedData"
temporary_result="$runtime_root/TarvenIOS-Layout.xcresult"
temporary_log="$runtime_root/xcodebuild.log"
final_result="$other_root/Test Results/TarvenIOS-Layout-$run_id.xcresult"
final_log="$other_root/Logs/TarvenIOS-Layout-$run_id.log"
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
  -scheme TarvenIOSLayoutTests -configuration Debug \
  -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$temporary_result" \
  "MOBILEVLCKIT_ROOT=$dependency_root" \
  CODE_SIGNING_ALLOWED=NO \
  -enableCodeCoverage NO -parallel-testing-enabled NO \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES \
  test 2>&1 | tee "$temporary_log"
print "iOS Layout test results: $final_result"
print "iOS Layout test log: $final_log"
