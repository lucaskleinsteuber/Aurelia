#!/bin/bash
# Publishes the current version as a GitHub Release of `origin`, tagged <version>-<build> at the
# pushed HEAD: the Linux server downloads that scripts/build-linux-server.sh made, which
# `sudo aurelia update` installs, and the Apple silicon Mac app that scripts/build-macos-release.sh
# made, as a disk image. GitHub adds the source code of the tag by itself. A release is visible to
# everyone who can see the repository; the owner wants every Mac/server version published this way.
# An existing published release is never changed. A new release stays a
# draft until every download is uploaded, so the Mac updater never sees a half-uploaded release.
# The release text comes from a notes file when there is one (see below).
# Once GitHub lists every download, the local build output of this version is deleted, because
# the release is the copy that is kept (AURELIA_KEEP_LOCAL_BUILDS=1 keeps it).
set -euo pipefail
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# The Linux desktop has an independent version counter and release channel. Its releases must
# never become the Mac/server updater's "latest" release.
if [ "${1:-}" = --linux-app ]; then
  shift
  exec bash "$repository_root/scripts/publish-linux-app-release.sh" "$@"
fi
[ "$#" -eq 0 ] || { echo "Usage: publish-release.sh [--linux-app]" >&2; exit 1; }
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

# The Mac app of exactly this version, signed and for Apple silicon only.
app="$other_root/Build/Build $build/Aurelia.app"
[ -d "$app" ] || { echo "Missing $app; run scripts/build-macos-release.sh first." >&2; exit 1; }
[ "$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")" = "$version" ] \
  && [ "$(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist")" = "$build" ] \
  || { echo "$app is not Aurelia $version ($build)." >&2; exit 1; }
archs=$(lipo -archs "$app/Contents/MacOS/Aurelia")
[ "$archs" = arm64 ] || { echo "The Mac app is not built for Apple silicon only ($archs)." >&2; exit 1; }
codesign --verify --deep --strict "$app" || { echo "The Mac app's signature is not valid." >&2; exit 1; }

head=$(git -C "$repository_root" rev-parse HEAD)
git -C "$repository_root" fetch --quiet origin
git -C "$repository_root" merge-base --is-ancestor "$head" origin/main \
  || { echo "Push HEAD to origin/main before publishing it." >&2; exit 1; }

# A disk image with the app and a shortcut to Applications to drag it onto.
# Releases up to 1.25.1 were universal; Intel Macs keep 1.25.1, whose updater looks only for
# the universal name and so never fetches an app it cannot run.
dmg="$output/Aurelia-$tag-macOS-arm64.dmg"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Aurelia.app"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -ov -fs HFS+ -format UDZO -volname "Aurelia $version" -srcfolder "$stage" "$dmg"
hdiutil verify -quiet "$dmg"
# One checksum list for every download; `aurelia update` picks its package's line by name.
(cd "$output" && shasum -a 256 "./$(basename "${linux[0]}")" "./$(basename "${linux[1]}")" "./$(basename "$dmg")" > SHA256SUMS)
files=("${linux[@]}" "$dmg" "$output/SHA256SUMS")

downloads="- **Mac:** Aurelia-$tag-macOS-arm64.dmg, for Macs with Apple silicon (Intel Macs stay on 1.25.1). Open it and drag Aurelia to Applications. It is signed for development and not notarized, so it runs on the Macs registered for this developer account.
- **Linux server:** the package for x64 or arm64; see docs/LINUX_SERVER.md. Installed servers update with \`sudo aurelia update\` or in Aurelia on a Mac under Settings › Server › Updates.
- **Source code:** attached by GitHub below."

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

notes="$notes

## Product versions

$(python3 "$repository_root/scripts/release-versions.py" --product mac --version "$version" --build "$build")"

# Large uploads sometimes fail over HTTP/2 with HTTP 408; retry them one by one over HTTP/1.1.
upload() {
  gh release upload "$tag" "$@" --clobber && return 0
  echo "Upload failed; retrying each download over HTTP/1.1." >&2
  local file
  for file in "$@"; do
    GODEBUG=http2client=0 gh release upload "$tag" "$file" --clobber || return 1
  done
}

cd "$repository_root"
if gh release view "$tag" >/dev/null 2>&1; then
  [ "$(gh release view "$tag" --json isDraft --jq .isDraft)" = true ] \
    || { echo "$tag is already published; published downloads are not replaced." >&2; exit 1; }
  upload "${files[@]}"
  gh release edit "$tag" --notes "$notes" --draft=false
else
  gh release create "$tag" --target "$head" --latest --draft \
    --title "Aurelia $version ($build)" --notes "$notes"
  upload "${files[@]}"
  gh release edit "$tag" --draft=false --latest
fi
echo "Published Aurelia $version ($build) for Mac and Linux as release $tag."

published=$(gh release view "$tag" --json assets --jq '.assets[].name')
for file in "${files[@]}"; do
  grep -qxF "$(basename "$file")" <<<"$published" \
    || { echo "GitHub does not list $(basename "$file"); the local build is kept." >&2; exit 1; }
done
if [ "${AURELIA_KEEP_LOCAL_BUILDS:-0}" != 1 ]; then
  rm -rf -- "$other_root/Build/Build $build" "$output"
  echo "Removed the local build output of $tag; the release is on GitHub."
fi
