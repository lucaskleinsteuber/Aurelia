#!/bin/zsh
set -euo pipefail

repository_root=${0:A:h:h}
source "$repository_root/scripts/workspace-paths.sh"
# Old builds and test results are removed first; see prune-workspace.sh.
/bin/sh "$repository_root/scripts/prune-workspace.sh" || true
unsigned=0
provisioning=0
device_id=""
while (( $# > 0 )); do
  case "$1" in
    --unsigned) unsigned=1 ;;
    --allow-provisioning-updates) provisioning=1 ;;
    --device)
      (( $# >= 2 )) || { print -u2 "--device requires an Apple TV identifier."; exit 2; }
      device_id=$2
      shift
      ;;
    *) print -u2 "Usage: scripts/build-tvos.sh [--unsigned] [--allow-provisioning-updates] [--device identifier]"; exit 2 ;;
  esac
  shift
done
if (( unsigned && provisioning )); then
  print -u2 "An unsigned build cannot request development provisioning updates."
  exit 2
fi

version=$(awk '/^MARKETING_VERSION = / {print $3}' "$repository_root/clients/tvos/Configuration/BuildNumber.xcconfig")
build_number=$(awk '/^CURRENT_PROJECT_VERSION = / {print $3}' "$repository_root/clients/tvos/Configuration/BuildNumber.xcconfig")
build_root=${AURELIA_TV_BUILD_ROOT:-"$other_root/Build/tvOS/$version-$build_number"}
mkdir -p "$build_root" "$other_root/Logs"
build_root=${build_root:A}
if [[ "$build_root" == "$repository_root" || ( "$build_root" == "$repository_root/"* && "$build_root" != "$repository_root/Local/"* ) ]]; then
  print -u2 "TV build output must be outside the checkout."
  exit 1
fi
dependency_root=${TVVLCKIT_ROOT:-"$repository_root/clients/tvos/Dependencies"}
TVVLCKIT_ROOT="$dependency_root" "$repository_root/scripts/prepare-tvvlckit.sh"
destination='generic/platform=tvOS'
if [[ -n "$device_id" ]]; then
  destination="platform=tvOS,id=$device_id"
fi
log="$other_root/Logs/Aurelia-TV-Build-$(date -u +%Y%m%dT%H%M%SZ)-$(uuidgen).log"
arguments=(
  -project "$repository_root/clients/tvos/AureliaTV.xcodeproj"
  -scheme AureliaTV -configuration Release
  -sdk appletvos -destination "$destination" -destination-timeout 30
  -derivedDataPath "$build_root/DerivedData"
  "TVVLCKIT_ROOT=$dependency_root"
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES
)
if (( unsigned )); then
  arguments+=(CODE_SIGNING_ALLOWED=NO)
elif (( provisioning )); then
  arguments+=(-allowProvisioningUpdates)
  if [[ -n "$device_id" ]]; then
    arguments+=(-allowProvisioningDeviceRegistration)
  fi
fi
DEVELOPER_DIR="$developer_dir" xcodebuild "${arguments[@]}" build 2>&1 | tee "$log"
app="$build_root/DerivedData/Build/Products/Release-appletvos/Aurelia.app"
framework="$app/Frameworks/TVVLCKit.framework/TVVLCKit"
if [[ ! -f "$app/Aurelia" || ! -f "$framework" || ! -f "$app/TVVLCKit-COPYING.txt" ]]; then
  print -u2 "The built TV application, player dependency or license is incomplete."
  exit 1
fi
if [[ "$(xcrun lipo -archs "$app/Aurelia")" != arm64 || "$(xcrun lipo -archs "$framework")" != arm64 ]]; then
  print -u2 "The TV application must contain only the arm64 device architecture."
  exit 1
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Info.plist")" != "$version" ||
      "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Info.plist")" != "$build_number" ]]; then
  print -u2 "The built TV version does not match its independent configuration."
  exit 1
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")" != com.lucas.aurelia.tvos ||
      "$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$app/Info.plist")" != 26.0 ||
      "$(/usr/libexec/PlistBuddy -c 'Print :UIDeviceFamily:0' "$app/Info.plist")" != 3 ]]; then
  print -u2 "The built application does not match the approved Apple TV identity or minimum OS."
  exit 1
fi
if (( unsigned )); then
  print "Unsigned device build verified; this is not an installable signed candidate."
else
  /usr/bin/codesign --verify --deep --strict "$app"
  if [[ ! -f "$app/embedded.mobileprovision" ]]; then
    print -u2 "The device build has no embedded development provisioning profile."
    exit 1
  fi
  print "Signed Apple TV device build verified."
fi
print "Application: $app"
print "Build log: $log"
