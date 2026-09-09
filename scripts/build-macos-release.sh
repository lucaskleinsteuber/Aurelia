#!/bin/zsh
set -euo pipefail

repository_root=${0:A:h:h}
other_root=${AURELIA_HOME_OTHER_ROOT:-"${repository_root:h}/Aurelia Home Other"}
developer_dir=${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}
dotnet_bin=${DOTNET_BIN:-"$HOME/.dotnet/dotnet"}
build_parent="$other_root/Build"
final_root="$build_parent/Build 9"
mkdir -p "$build_parent"
stage_root=$(mktemp -d "$build_parent/.build9.XXXXXX")
derived_data="$stage_root/DerivedData"
publish_root="$stage_root/Server"
candidate="$stage_root/Aurelia Home.app"

cleanup() {
  rm -rf -- "$stage_root"
}
trap cleanup EXIT

mkdir -p "$publish_root"
"$repository_root/scripts/prepare-vlckit.sh"
"$repository_root/scripts/verify-build-number.sh"

for runtime in osx-arm64 osx-x64; do
  "$dotnet_bin" restore "$repository_root/src/Aurelia.Home.Server/Aurelia.Home.Server.csproj" \
    --runtime "$runtime"
  "$dotnet_bin" publish "$repository_root/src/Aurelia.Home.Server/Aurelia.Home.Server.csproj" \
    --configuration Release \
    --runtime "$runtime" \
    --self-contained true \
    --no-restore \
    --output "$publish_root/$runtime"
done

DEVELOPER_DIR="$developer_dir" xcodebuild \
  -project "$repository_root/clients/macos/AureliaHome.xcodeproj" \
  -scheme AureliaHome \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived_data" \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  build

/usr/bin/ditto "$derived_data/Build/Products/Release/Aurelia Home.app" "$candidate"
mkdir -p "$candidate/Contents/Resources/Server"
for runtime in osx-arm64 osx-x64; do
  /usr/bin/ditto "$publish_root/$runtime" "$candidate/Contents/Resources/Server/$runtime"
done

while IFS= read -r -d '' binary; do
  if file "$binary" | grep -q 'Mach-O'; then
    if [[ "${binary:t}" == 'Aurelia.Home.Server' ]]; then
      codesign --force --sign 'Apple Development' --options runtime --timestamp=none \
        --entitlements "$repository_root/clients/macos/Configuration/ServerRuntime.entitlements" \
        "$binary"
    else
      codesign --force --sign 'Apple Development' --options runtime --timestamp=none "$binary"
    fi
  fi
done < <(find "$candidate/Contents/Resources/Server" -type f -print0)

codesign --force --sign 'Apple Development' --options runtime --timestamp=none \
  "$candidate/Contents/Frameworks/VLCKit.framework"
codesign --force --sign 'Apple Development' --options runtime --timestamp=none \
  "$candidate/Contents/Helpers/Aurelia Home Server Host.app"
codesign --force --sign 'Apple Development' --options runtime --timestamp=none \
  --preserve-metadata=entitlements "$candidate"
codesign --verify --deep --strict --verbose=2 "$candidate"

if [[ -e "$final_root" ]]; then
  if [[ "$final_root" != "$other_root/Build/Build 9" ]]; then
    echo "Refusing to replace an unexpected build directory." >&2
    exit 1
  fi
  rm -rf -- "$final_root"
fi
mkdir -p "$final_root"
/usr/bin/ditto "$candidate" "$final_root/Aurelia Home.app"
/usr/bin/ditto "$publish_root" "$final_root/Server"

echo "Build 9 release is available at $final_root"
