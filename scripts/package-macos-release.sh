#!/bin/zsh
set -euo pipefail

repository_root=${0:A:h:h}
source "$repository_root/scripts/workspace-paths.sh"
candidate=${1:?Provide the verified Developer ID signed Aurelia.app.}
candidate=${candidate:A}
[[ -d "$candidate" && "${candidate:t}" == Aurelia.app ]] || {
  echo "Expected an Aurelia.app bundle." >&2; exit 1
}
/usr/bin/codesign --verify --deep --strict "$candidate"
signature=$(/usr/bin/codesign --display --verbose=4 "$candidate" 2>&1)
[[ "$signature" == *"Authority=Developer ID Application:"* && "$signature" == *"Timestamp="* ]] || {
  echo "Refusing to package a development, ad-hoc, or untimestamped signature as a public release." >&2
  exit 1
}
[[ -n "${AURELIA_NOTARY_PROFILE:-}" ]] || {
  echo "Set AURELIA_NOTARY_PROFILE to a stored notarytool Keychain profile." >&2; exit 1
}
info="$candidate/Contents/Info.plist"
identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")
[[ "$identifier" == com.lucas.aurelia.media ]] || {
  echo "Not the Aurelia bundle identity." >&2; exit 1
}
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info")
[[ "$version" == <->.<-> || "$version" == <->.<->.<-> ]] && [[ "$build" == <-> ]] || {
  echo "Invalid release version or build number." >&2; exit 1
}
# One package per architecture, named by it: arm64 (Apple silicon) or x64 (Intel).
case "$(/usr/bin/lipo -archs "$candidate/Contents/MacOS/Aurelia")" in
  arm64) arch=arm64; xcode_arch=arm64; runtime=osx-arm64 ;;
  x86_64) arch=x64; xcode_arch=x86_64; runtime=osx-x64 ;;
  *) echo "Expected an app built for one architecture." >&2; exit 1 ;;
esac
name="Aurelia-$version-build-$build-macOS-$arch"
output="$other_root/Releases/$name"
[[ ! -e "$output" ]] || { echo "Release output already exists; refusing to overwrite it." >&2; exit 1; }
mkdir -p "$other_root/Releases"
stage=$(mktemp -d "$other_root/Releases/.package.XXXXXX")
trap '[[ "$stage" == "$other_root/Releases/.package."* ]] && find "$stage" -depth -delete' EXIT
/usr/bin/ditto "$candidate" "$stage/Aurelia.app"
for binary in "$stage/Aurelia.app/Contents/MacOS/Aurelia" \
  "$stage/Aurelia.app/Contents/Helpers/Aurelia Server Host.app/Contents/MacOS/AureliaServerHost"; do
  [[ "$(/usr/bin/lipo -archs "$binary")" == "$xcode_arch" ]] || { echo "Mixed architectures in $binary." >&2; exit 1; }
done
[[ -x "$stage/Aurelia.app/Contents/Resources/Server/$runtime/Aurelia.Server" ]] || {
  echo "Missing server payload: $runtime" >&2; exit 1
}
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$stage/Aurelia.app" "$stage/submission.zip"
DEVELOPER_DIR="$developer_dir" /usr/bin/xcrun notarytool submit "$stage/submission.zip" \
  --keychain-profile "$AURELIA_NOTARY_PROFILE" --wait --output-format json >"$stage/notarization.json"
/usr/bin/plutil -extract status raw -o - "$stage/notarization.json" | /usr/bin/grep -qx Accepted || {
  echo "Apple did not accept this package. No release artifact was published." >&2; exit 1
}
DEVELOPER_DIR="$developer_dir" /usr/bin/xcrun stapler staple "$stage/Aurelia.app"
DEVELOPER_DIR="$developer_dir" /usr/bin/xcrun stapler validate "$stage/Aurelia.app"
/usr/sbin/spctl --assess --type execute --verbose=2 "$stage/Aurelia.app"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$stage/Aurelia.app" "$stage/$name.zip"
(cd "$stage" && /usr/bin/shasum -a 256 "$name.zip" >"SHA256SUMS.txt")
mkdir "$output"
/usr/bin/ditto "$stage/$name.zip" "$output/$name.zip"
/usr/bin/ditto "$stage/SHA256SUMS.txt" "$output/SHA256SUMS.txt"
/usr/bin/ditto "$stage/notarization.json" "$output/notarization.json"
echo "Notarized package and checksum: $output"
