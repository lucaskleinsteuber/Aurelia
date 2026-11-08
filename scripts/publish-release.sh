#!/bin/bash
# Publish one verified product from pushed source. The Mac retains the Latest channel,
# while server and Linux desktop releases use their own tags.
#   --beta    publishes a GitHub pre-release: only apps with "Beta updates" on offer it.
#   --promote <tag>  turns a tested beta into the stable release without rebuilding it.
set -euo pipefail
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "${1:-}" = --promote ]; then
  shift
  exec bash "$repository_root/scripts/promote-release.sh" "$@"
fi
export AURELIA_RELEASE_BETA=false
if [ "${1:-}" = --beta ]; then
  AURELIA_RELEASE_BETA=true
  shift
fi
beta=$AURELIA_RELEASE_BETA
if [ "${1:-}" = --linux-app ]; then
  shift
  exec bash "$repository_root/scripts/publish-linux-app-release.sh" "$@"
fi
case "$#:${1:-}" in
  0:) product=Mac; latest=true ;;
  1:--server) product=Server; latest=false ;;
  *) echo "Usage: publish-release.sh [--beta] [--server | --linux-app] | --promote <tag>" >&2; exit 1 ;;
esac
# A beta never becomes GitHub's Latest release; promoting it later does.
if [ "$beta" = true ]; then latest=false; fi
. "$repository_root/scripts/workspace-paths.sh"
"$repository_root/scripts/verify-build-number.sh"

if [ "$product" = Server ]; then
  project="$repository_root/src/Aurelia.Server/Aurelia.Server.csproj"
  version=$("$DOTNET_BIN" msbuild "$project" -getProperty:Version)
  build=$("$DOTNET_BIN" msbuild "$project" -getProperty:AureliaBuildNumber)
  build_tag="$version-$build"
  tag="server-$build_tag"
  output="$other_root/Build/Linux/$build_tag"
  files=("$output/Aurelia-Server-$build_tag-linux-x64.tar.gz"
    "$output/Aurelia-Server-$build_tag-linux-arm64.tar.gz" "$output/SHA256SUMS")
  for file in "${files[@]}"; do
    [ -s "$file" ] || { echo "Missing $file; run scripts/build-linux-server.sh first." >&2; exit 1; }
  done
  (cd "$output" && shasum -a 256 -c SHA256SUMS >/dev/null)
  title="Aurelia Server $version ($build)"
  downloads="- **Linux server:** Download the x64 or arm64 package. Existing installations can use \`sudo aurelia update\` or Settings › Updates › Server Updates in Aurelia for Mac."
else
  config="$repository_root/clients/macos/Configuration/BuildNumber.xcconfig"
  version=$(sed -n 's/^MARKETING_VERSION = //p' "$config")
  build=$(sed -n 's/^CURRENT_PROJECT_VERSION = //p' "$config")
  tag="$version-$build"
  output="$other_root/Build/MacRelease/$tag"
  mkdir -p "$output"
  stage=$(mktemp -d)
  trap 'rm -rf "$stage"' EXIT
  files=()
  # One disk image per architecture: arm64 for Apple silicon, x64 for Intel Macs.
  for arch in arm64 x64; do
    folder="$other_root/Build/Build $build"
    expected=arm64
    if [ "$arch" = x64 ]; then folder="$folder x64"; expected=x86_64; fi
    app="$folder/Aurelia.app"
    [ -d "$app" ] || { echo "Missing $app; run AURELIA_MAC_ARCH=$arch scripts/build-macos-release.sh first." >&2; exit 1; }
    [ "$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")" = "$version" ] \
      && [ "$(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist")" = "$build" ] \
      || { echo "$app is not Aurelia $version ($build)." >&2; exit 1; }
    [ "$(lipo -archs "$app/Contents/MacOS/Aurelia")" = "$expected" ] \
      || { echo "$app is not built for $expected only." >&2; exit 1; }
    codesign --verify --deep --strict "$app"
    dmg="$output/Aurelia-$tag-macOS-$arch.dmg"
    rm -rf "$stage/image" && mkdir "$stage/image"
    ditto "$app" "$stage/image/Aurelia.app"
    ln -s /Applications "$stage/image/Applications"
    hdiutil create -quiet -ov -fs HFS+ -format UDZO -volname "Aurelia $version" -srcfolder "$stage/image" "$dmg"
    hdiutil verify -quiet "$dmg"
    files+=("$dmg")
  done
  # The updater of 1.34 asks for the universal name; it gets the Apple silicon image, the only
  # Macs that ran 1.34. Updaters from 2.0 on ask for their own architecture.
  transition="$output/Aurelia-$tag-macOS-universal.dmg"
  cp -c "$output/Aurelia-$tag-macOS-arm64.dmg" "$transition"
  files+=("$transition")
  (cd "$output" && shasum -a 256 $(for file in "${files[@]}"; do printf './%s ' "${file##*/}"; done) > SHA256SUMS)
  files+=("$output/SHA256SUMS")
  title="Aurelia for Mac $version ($build)"
  downloads="- **Mac with Apple silicon (M1 and newer):** Aurelia-$tag-macOS-arm64.dmg
- **Mac with Intel processor:** Aurelia-$tag-macOS-x64.dmg

Open the disk image and drag Aurelia to Applications. This development-signed build runs on Macs registered for its developer account. Aurelia-$tag-macOS-universal.dmg is the Apple silicon image under the name the updater of version 1.34 asks for."
fi

head=$(git -C "$repository_root" rev-parse HEAD)
git -C "$repository_root" fetch --quiet origin
git -C "$repository_root" merge-base --is-ancestor "$head" origin/main \
  || { echo "Push HEAD to origin/main before publishing it." >&2; exit 1; }

# Readable notes (what is new, what was fixed) come from a Markdown file, by default
# "<workspace>/Release Notes/<version>-<build>.md"; AURELIA_RELEASE_NOTES selects another file.
# The Mac updater shows this text in its update dialog. Without a file the download list is used.
notes_file=${AURELIA_RELEASE_NOTES:-"$other_root/Release Notes/$tag.md"}
if [ -n "${AURELIA_RELEASE_NOTES:-}" ] && [ ! -f "$notes_file" ]; then
  echo "Missing release notes $notes_file." >&2
  exit 1
fi
if [ -f "$notes_file" ] && grep -q '[^[:space:]]' "$notes_file"; then
  notes="$(cat "$notes_file")

## Downloads

$downloads"
else
  echo "No release notes at $notes_file; using the download list only." >&2
  notes="Aurelia $version ($build).

$downloads"
fi

cd "$repository_root"
repository=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
notes="$notes

$(python3 "$repository_root/scripts/release-links.py" "$repository" --candidate "$product" "$version" "$build" "$tag")"
if [ "$beta" = true ]; then
  title="$title Beta"
  notes="$(cat "$repository_root/scripts/beta-notice.md")

$notes"
fi
notes_output=$(mktemp)
trap 'rm -f "$notes_output"; if [ -n "${stage:-}" ]; then rm -rf "$stage"; fi' EXIT
printf '%s\n' "$notes" > "$notes_output"

# Large uploads sometimes fail over HTTP/2 with HTTP 408; retry them one by one over HTTP/1.1.
upload() {
  gh release upload "$tag" "$@" --clobber && return 0
  echo "Upload failed; retrying each download over HTTP/1.1." >&2
  local file
  for file in "$@"; do
    GODEBUG=http2client=0 gh release upload "$tag" "$file" --clobber || return 1
  done
}

if gh release view "$tag" >/dev/null 2>&1; then
  [ "$(gh release view "$tag" --json isDraft --jq .isDraft)" = true ] \
    || { echo "$tag is already published; published downloads are not replaced." >&2; exit 1; }
else
  gh release create "$tag" --target "$head" --latest="$latest" --prerelease="$beta" --draft \
    --title "$title" --notes-file "$notes_output"
fi
upload "${files[@]}"
assets=$(gh release view "$tag" --json apiUrl --jq .apiUrl)
assets=$(gh api "$assets" --jq .assets)
jq -e --argjson count "${#files[@]}" 'length == $count' <<<"$assets" >/dev/null
for file in "${files[@]}"; do
  digest=$(shasum -a 256 "$file" | cut -d ' ' -f1)
  jq -e --arg name "${file##*/}" --arg digest "sha256:$digest" \
    'any(.[]; .name == $name and .state == "uploaded" and .digest == $digest)' \
    <<<"$assets" >/dev/null || { echo "Could not verify the uploaded ${file##*/}." >&2; exit 1; }
done
gh release edit "$tag" --notes-file "$notes_output" --draft=false --latest="$latest" \
  --prerelease="$beta"
echo "Published $title as $tag."

if [ "${AURELIA_KEEP_LOCAL_BUILDS:-0}" != 1 ]; then
  if [ "$product" = Mac ]; then rm -rf -- "$other_root/Build/Build $build" "$other_root/Build/Build $build x64"; fi
  rm -rf -- "$output"
fi
