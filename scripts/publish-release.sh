#!/bin/bash
# Publish one verified product from pushed source. The Mac retains the Latest channel,
# while server and Linux desktop releases use their own tags.
set -euo pipefail
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "${1:-}" = --linux-app ]; then
  shift
  exec bash "$repository_root/scripts/publish-linux-app-release.sh" "$@"
fi
case "$#:${1:-}" in
  0:) product=Mac; latest=true ;;
  1:--server) product=Server; latest=false ;;
  *) echo "Usage: publish-release.sh [--server | --linux-app]" >&2; exit 1 ;;
esac
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
  app="$other_root/Build/Build $build/Aurelia.app"
  [ -d "$app" ] || { echo "Missing $app; run scripts/build-macos-release.sh first." >&2; exit 1; }
  [ "$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")" = "$version" ] \
    && [ "$(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist")" = "$build" ] \
    || { echo "$app is not Aurelia $version ($build)." >&2; exit 1; }
  [ "$(lipo -archs "$app/Contents/MacOS/Aurelia")" = arm64 ] \
    || { echo "The Mac app must be built for Apple silicon only." >&2; exit 1; }
  codesign --verify --deep --strict "$app"
  mkdir -p "$output"
  dmg="$output/Aurelia-$tag-macOS-arm64.dmg"
  stage=$(mktemp -d)
  trap 'rm -rf "$stage"' EXIT
  ditto "$app" "$stage/Aurelia.app"
  ln -s /Applications "$stage/Applications"
  hdiutil create -quiet -ov -fs HFS+ -format UDZO -volname "Aurelia $version" -srcfolder "$stage" "$dmg"
  hdiutil verify -quiet "$dmg"
  (cd "$output" && shasum -a 256 "./${dmg##*/}" > SHA256SUMS)
  files=("$dmg" "$output/SHA256SUMS")
  title="Aurelia $version ($build)"
  downloads="- **Mac:** Download ${dmg##*/} for Apple silicon. Open it and drag Aurelia to Applications. This development-signed build runs on Macs registered for its developer account."
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
  gh release create "$tag" --target "$head" --latest="$latest" --draft \
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
gh release edit "$tag" --notes-file "$notes_output" --draft=false --latest="$latest"
echo "Published $title as $tag."

if [ "${AURELIA_KEEP_LOCAL_BUILDS:-0}" != 1 ]; then
  if [ "$product" = Mac ]; then rm -rf -- "$other_root/Build/Build $build"; fi
  rm -rf -- "$output"
fi
