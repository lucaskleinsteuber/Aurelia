#!/bin/zsh
# Builds the iPhone and iPad app with warnings as errors.
#
#   zsh scripts/build-ios.sh                    Release build for the iOS Simulator, unsigned
#   zsh scripts/build-ios.sh --device <udid>    Release build signed for development and installed
#                                               on that paired iPhone or iPad (cable or Wi-Fi);
#                                               `xcrun devicectl list devices` shows the identifier
set -euo pipefail

device=""
if [[ "${1:-}" == --device ]]; then
  device=${2:?Give the device identifier after --device.}
fi

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
  -scheme AureliaIOS -configuration Release -destination-timeout 30
  -derivedDataPath "$build_root/DerivedData"
  "MOBILEVLCKIT_ROOT=$dependency_root"
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES
)
if [[ -n "$device" ]]; then
  # A free development profile for this device, requested from Apple through Xcode's account.
  arguments+=(-sdk iphoneos -destination "id=$device"
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration)
  products=Release-iphoneos
else
  arguments+=(-sdk iphonesimulator -destination "generic/platform=iOS Simulator"
    CODE_SIGNING_ALLOWED=NO)
  products=Release-iphonesimulator
fi

DEVELOPER_DIR="$developer_dir" xcodebuild "${arguments[@]}" build 2>&1 | tee "$log"
app="$build_root/DerivedData/Build/Products/$products/Aurelia.app"
framework="$app/Frameworks/MobileVLCKit.framework/MobileVLCKit"

if [[ ! -f "$app/Aurelia" || ! -f "$framework" || ! -f "$app/MobileVLCKit-COPYING.txt" ]]; then
  print -u2 "The built iOS application, player dependency or license is incomplete."
  exit 1
fi

if [[ -n "$device" ]]; then
  codesign --verify --deep --strict "$app"
  # Installing replaces only the app; its sign-in and settings on the device stay.
  DEVELOPER_DIR="$developer_dir" xcrun devicectl device install app --device "$device" "$app"
  print "iOS app built and installed on $device: $app"
else
  print "iOS simulator build succeeded: $app"
fi
