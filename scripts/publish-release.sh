#!/bin/bash
# Publishes the current version as a GitHub Release of `origin`, tagged <version>-<build> at the
# pushed HEAD: the Linux server downloads that scripts/build-linux-server.sh made, which
# `sudo aurelia update` installs, and the universal Mac app that scripts/build-macos-release.sh
# made, as a disk image. GitHub adds the source code of the tag by itself. A release is visible to
# everyone who can see the repository: run this only with the owner's approval for that version.
# An existing release of the same tag gets the downloads added or replaced.
set -euo pipefail
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repository_root/scripts/workspace-paths.sh"
project="$repository_root/src/Aurelia.Server/Aurelia.Server.csproj"

version=$("$DOTNET_BIN" msbuild "$project" -getProperty:Version)
build=$("$DOTNET_BIN" msbuild "$project" -getProperty:AureliaBuildNumber)
tag="$version-$build"
output="$other_root/Build/Linux/$tag"
linux=("$output/Aurelia-Server-$tag-linux-x64.tar.gz" "$output/Aurelia-Server-$tag-linux-arm64.tar.gz")
for file in "${linux[@]}" "$output/SHA256SUMS"; do
  [ -f "$file" ] || { echo "Missing $file; run scripts/build-linux-server.sh first." >&2; exit 1; }
done
(cd "$output" && shasum -a 256 -c SHA256SUMS >/dev/null) || { echo "The downloads do not match SHA256SUMS." >&2; exit 1; }

# The Mac app of exactly this version, signed and with both architectures.
app="$other_root/Build/Build $build/Aurelia.app"
[ -d "$app" ] || { echo "Missing $app; run scripts/build-macos-release.sh first." >&2; exit 1; }
[ "$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")" = "$version" ] \
  && [ "$(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist")" = "$build" ] \
  || { echo "$app is not Aurelia $version ($build)." >&2; exit 1; }
archs=$(lipo -archs "$app/Contents/MacOS/Aurelia")
[[ " $archs " == *" x86_64 "* && " $archs " == *" arm64 "* ]] \
  || { echo "The Mac app is not universal ($archs)." >&2; exit 1; }
codesign --verify --deep --strict "$app" || { echo "The Mac app's signature is not valid." >&2; exit 1; }

head=$(git -C "$repository_root" rev-parse HEAD)
git -C "$repository_root" fetch --quiet origin
git -C "$repository_root" merge-base --is-ancestor "$head" origin/main \
  || { echo "Push HEAD to origin/main before publishing it." >&2; exit 1; }

# A disk image with the app and a shortcut to Applications to drag it onto.
dmg="$output/Aurelia-$tag-macOS-universal.dmg"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Aurelia.app"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -ov -fs HFS+ -format UDZO -volname "Aurelia $version" -srcfolder "$stage" "$dmg"
hdiutil verify -quiet "$dmg"
# One checksum list for every download; `aurelia update` picks its package's line by name.
(cd "$output" && shasum -a 256 "./$(basename "${linux[0]}")" "./$(basename "${linux[1]}")" "./$(basename "$dmg")" > SHA256SUMS)
files=("${linux[@]}" "$dmg" "$output/SHA256SUMS")

notes="Aurelia $version ($build).

- **Mac:** Aurelia-$tag-macOS-universal.dmg, for Apple silicon and Intel. Open it and drag Aurelia to Applications. It is signed for development and not notarized, so it runs on the Macs registered for this developer account.
- **Linux server:** the package for x64 or arm64; see docs/LINUX_SERVER.md. Installed servers update with \`sudo aurelia update\` or in Aurelia on a Mac under Settings › Server › Updates.
- **Source code:** attached by GitHub below."

cd "$repository_root"
if gh release view "$tag" >/dev/null 2>&1; then
  gh release upload "$tag" "${files[@]}" --clobber
  gh release edit "$tag" --notes "$notes"
else
  gh release create "$tag" "${files[@]}" --target "$head" --latest \
    --title "Aurelia $version ($build)" --notes "$notes"
fi
echo "Published Aurelia $version ($build) for Mac and Linux as release $tag."
