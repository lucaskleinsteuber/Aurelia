#!/bin/zsh
set -euo pipefail

repository_root=${0:A:h:h}
source "$repository_root/scripts/workspace-paths.sh"
# Old builds and test results are removed first; see prune-workspace.sh.
/bin/sh "$repository_root/scripts/prune-workspace.sh" || true

version=$(awk '/^MARKETING_VERSION = / {print $3}' "$repository_root/clients/ios/Configuration/BuildNumber.xcconfig")
build_number=$(awk '/^CURRENT_PROJECT_VERSION = / {print $3}' "$repository_root/clients/ios/Configuration/BuildNumber.xcconfig")
build_root=${AURELIA_IOS_BUILD_ROOT:-"$other_root/Build/iOS/$version-$build_number"}
mkdir -p "$build_root" "$other_root/Logs"
build_root=${build_root:A}

if [[ "$build_root" == "$repository_root" || ( "$build_root" == "$repository_root/"* && "$build_root" != "$repository_root/Local/"* ) ]]; then
  print -u2 "iOS build output must be outside the checkout."
  exit 1
fi

dependency_root=${MOBILEVLCKIT_ROOT:-"$repository_root/clients/ios/Dependencies"}
MOBILEVLCKIT_ROOT="$dependency_root" "$repository_root/scripts/prepare-ios-vlckit.sh"

log="$other_root/Logs/Aurelia-iOS-Build-$(date -u +%Y%m%dT%H%M%SZ)-$(uuidgen).log"
arguments=(
  -project "$repository_root/clients/ios/AureliaIOS.xcodeproj"
  -scheme AureliaIOS -configuration Release
  -sdk iphonesimulator -destination "generic/platform=iOS Simulator" -destination-timeout 30
  -derivedDataPath "$build_root/DerivedData"
  "MOBILEVLCKIT_ROOT=$dependency_root"
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES
  CODE_SIGNING_ALLOWED=NO
)

DEVELOPER_DIR="$developer_dir" xcodebuild "${arguments[@]}" build 2>&1 | tee "$log"
app="$build_root/DerivedData/Build/Products/Release-iphonesimulator/Aurelia.app"
framework="$app/Frameworks/MobileVLCKit.framework/MobileVLCKit"

if [[ ! -f "$app/Aurelia" || ! -f "$framework" || ! -f "$app/MobileVLCKit-COPYING.txt" ]]; then
  print -u2 "The built iOS application, player dependency or license is incomplete."
  exit 1
fi

print "iOS simulator build succeeded: $app"
