#!/bin/bash
# Publish one verified product from pushed source. Every product has its own tags; GitHub's Latest
# is the newest stable server (direct stable --server or promote-release.sh), never a Mac release, which are all betas.
#   --beta    publishes a GitHub pre-release: only apps with "Beta updates" on offer it.
#   --promote <tag>  turns a tested beta into the stable release without rebuilding it.
set -euo pipefail
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "${1:-}" = --promote ]; then
  shift
  exec bash "$repository_root/scripts/promote-release.sh" "$@"
fi
export TARVEN_RELEASE_BETA=false
if [ "${1:-}" = --beta ]; then
  TARVEN_RELEASE_BETA=true
  shift
fi
beta=$TARVEN_RELEASE_BETA
if [ "${1:-}" = --linux-app ]; then
  shift
  exec bash "$repository_root/scripts/publish-linux-app-release.sh" "$@"
fi
case "$#:${1:-}" in
  0:)
    product=Mac; latest=false
    # The Mac app is development-signed and runs only on registered Macs, so it ships as betas
    # only (owner's decision, 11.11.2026); everyone else uses Tarven in a browser.
    [ "$beta" = true ] || { echo "The Mac app is published as a beta only: use publish-release.sh --beta." >&2; exit 1; } ;;
  1:--server) product=Server; latest=true ;;
  *) echo "Usage: publish-release.sh [--beta] [--server | --linux-app] | --promote <tag>" >&2; exit 1 ;;
esac
# A beta never becomes GitHub's Latest release; promoting it later does.
if [ "$beta" = true ]; then latest=false; fi
. "$repository_root/scripts/workspace-paths.sh"
"$repository_root/scripts/verify-build-number.sh"

# Published binaries must come from a clean commit that is already pushed to origin/main (audit REL-REPO-007).
[ -z "$(git -C "$repository_root" status --porcelain --untracked-files=normal)" ] \
  || { echo "Commit all source changes before publishing." >&2; exit 1; }
head=$(git -C "$repository_root" rev-parse HEAD)
git -C "$repository_root" fetch --quiet --tags origin
git -C "$repository_root" merge-base --is-ancestor "$head" origin/main \
  || { echo "Push HEAD to origin/main before publishing it." >&2; exit 1; }

verify_source_provenance() {
  local dir=$1 label=$2
  [ -f "$dir/SOURCE_COMMIT" ] && [ "$(cat "$dir/SOURCE_COMMIT")" = "$head" ] \
    && [ "$(cat "$dir/SOURCE_CLEAN" 2>/dev/null)" = true ] \
    || { echo "Rebuild $label from this committed, clean source before publishing." >&2; exit 1; }
}

verify_rising_build() {
  local prefix=$1 current_tag=$2 current_build=$3
  # An existing tag may not be moved or reused for another commit.
  local tag_hash
  tag_hash=$(git -C "$repository_root" ls-remote origin "refs/tags/$current_tag" "refs/tags/$current_tag^{}" | tail -1 | cut -f1)
  [ -z "$tag_hash" ] || [ "$tag_hash" = "$head" ] \
    || { echo "The published tag $current_tag points at another commit." >&2; exit 1; }
  # Never reuse or decrease a product's build number compared to published tags (audit REL-REPO-009).
  local max_published_build
  max_published_build=$(git -C "$repository_root" ls-remote --tags origin \
    | awk -v prefix="$prefix" -v current="$current_tag" '
        $2 ~ /^refs\/tags\// && $2 !~ /\^\{\}$/ {
          t = substr($2, 11)
          if (t == current) next
          if (t ~ ("^" prefix "[0-9]+\\.[0-9]+\\.[0-9]+-[0-9]+$")) {
            b = t; sub(/^.*-/, "", b)
            if (b + 0 > max) max = b + 0
          }
        }
        END { print max + 0 }')
  if [ "$current_build" -le "$max_published_build" ]; then
    echo "$product build $current_build must be higher than the newest published build ($max_published_build)." >&2
    exit 1
  fi
}

if [ "$product" = Server ]; then
  project="$repository_root/src/Tarven.Server/Tarven.Server.csproj"
  version=$("$DOTNET_BIN" msbuild "$project" -getProperty:Version)
  build=$("$DOTNET_BIN" msbuild "$project" -getProperty:TarvenBuildNumber)
  build_tag="$version-$build"
  tag="server-$build_tag"
  verify_rising_build "server-" "$tag" "$build"
  output="$other_root/Build/Linux/$build_tag"
  verify_source_provenance "$output" "the Linux server packages"
  # The Aurelia-Server packages are the same packages for servers from before the rename to
  # Tarven, which update only under that name (scripts/build-linux-server.sh).
  files=("$output/Tarven-Server-$build_tag-linux-x64.tar.gz"
    "$output/Tarven-Server-$build_tag-linux-arm64.tar.gz"
    "$output/Aurelia-Server-$build_tag-linux-x64.tar.gz"
    "$output/Aurelia-Server-$build_tag-linux-arm64.tar.gz" "$output/SHA256SUMS")
  for file in "${files[@]}"; do
    [ -s "$file" ] || { echo "Missing $file; run scripts/build-linux-server.sh first." >&2; exit 1; }
  done
  (cd "$output" && shasum -a 256 -c SHA256SUMS >/dev/null)
  # `tarven update`, the one-line installer and the Docker build install nothing whose SHA256SUMS
  # lacks the owner's minisign signature (docs/LINUX_UPDATE_SIGNING.md). The secret key stays on
  # this Mac and never goes to GitHub.
  command -v minisign >/dev/null \
    || { echo "Install minisign (brew install minisign) to sign the release." >&2; exit 1; }
  signing_key="${TARVEN_MINISIGN_SECRET_KEY:-$HOME/.minisign/tarven-linux.key}"
  # The same key, under the name it was created with before the rename to Tarven.
  [ -n "${TARVEN_MINISIGN_SECRET_KEY:-}" ] || [ -s "$signing_key" ] || signing_key="$HOME/.minisign/aurelia-linux.key"
  [ -s "$signing_key" ] \
    || { echo "Missing the minisign secret key $signing_key; see docs/LINUX_UPDATE_SIGNING.md." >&2; exit 1; }
  public_key=$(sed -n 's/^signing_public_key=\([A-Za-z0-9+\/=]*\)$/\1/p' "$repository_root/packaging/linux/tarven")
  [ -n "$public_key" ] || { echo "packaging/linux/tarven names no signing key." >&2; exit 1; }
  rm -f "$output/SHA256SUMS.minisig"
  minisign -S -s "$signing_key" -m "$output/SHA256SUMS" -x "$output/SHA256SUMS.minisig" \
    -t "Tarven Server $version ($build)"
  # Check with the exact key the installed servers carry, before anything is uploaded.
  minisign -V -P "$public_key" -m "$output/SHA256SUMS" -x "$output/SHA256SUMS.minisig" >/dev/null \
    || { echo "The signature does not match the servers' public key; nothing was uploaded." >&2; exit 1; }
  files+=("$output/SHA256SUMS.minisig")
  title="Tarven Server $version ($build)"
  downloads=$(cat <<EOF
- **Linux x64:** \`Tarven-Server-$build_tag-linux-x64.tar.gz\`
- **Linux arm64 (e.g. Raspberry Pi):** \`Tarven-Server-$build_tag-linux-arm64.tar.gz\`
- **Updating an existing installation:** Run \`sudo tarven update\` or use **Settings › Updates › Server Updates** in Tarven.
EOF
)
else
  config="$repository_root/clients/macos/Configuration/BuildNumber.xcconfig"
  version=$(sed -n 's/^MARKETING_VERSION = //p' "$config")
  build=$(sed -n 's/^CURRENT_PROJECT_VERSION = //p' "$config")
  tag="$version-$build"
  verify_rising_build "" "$tag" "$build"
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
    app="$folder/Tarven.app"
    [ -d "$app" ] || { echo "Missing $app; run TARVEN_MAC_ARCH=$arch scripts/build-macos-release.sh first." >&2; exit 1; }
    verify_source_provenance "$folder" "$app"
    [ "$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")" = "$version" ] \
      && [ "$(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist")" = "$build" ] \
      || { echo "$app is not Tarven $version ($build)." >&2; exit 1; }
    [ "$(lipo -archs "$app/Contents/MacOS/Tarven")" = "$expected" ] \
      || { echo "$app is not built for $expected only." >&2; exit 1; }
    codesign --verify --deep --strict "$app"
    dmg="$output/Tarven-$tag-macOS-$arch.dmg"
    rm -rf "$stage/image" && mkdir "$stage/image"
    ditto "$app" "$stage/image/Tarven.app"
    ln -s /Applications "$stage/image/Applications"
    hdiutil create -quiet -ov -fs HFS+ -format UDZO -volname "Tarven $version" -srcfolder "$stage/image" "$dmg"
    hdiutil verify -quiet "$dmg"
    files+=("$dmg")
  done
  basenames=()
  for file in "${files[@]}"; do basenames+=("./${file##*/}"); done
  (cd "$output" && shasum -a 256 "${basenames[@]}" > SHA256SUMS)
  files+=("$output/SHA256SUMS")
  # The Mac updater installs nothing whose SHA256SUMS lacks the owner's minisign signature. It is
  # made in minisign's legacy format (-l), which the app checks with CryptoKit.
  command -v minisign >/dev/null \
    || { echo "Install minisign (brew install minisign) to sign the release." >&2; exit 1; }
  signing_key="${TARVEN_MINISIGN_SECRET_KEY:-$HOME/.minisign/tarven-linux.key}"
  # The same key, under the name it was created with before the rename to Tarven.
  [ -n "${TARVEN_MINISIGN_SECRET_KEY:-}" ] || [ -s "$signing_key" ] || signing_key="$HOME/.minisign/aurelia-linux.key"
  [ -s "$signing_key" ] \
    || { echo "Missing the minisign secret key $signing_key; see docs/LINUX_UPDATE_SIGNING.md." >&2; exit 1; }
  public_key=$(sed -n 's/.*static let publicKey = "\([A-Za-z0-9+\/=]*\)".*/\1/p' \
    "$repository_root/clients/macos/Tarven/Updates/AppUpdateSignature.swift")
  [ -n "$public_key" ] || { echo "AppUpdateSignature names no public key." >&2; exit 1; }
  rm -f "$output/SHA256SUMS.minisig"
  minisign -S -l -s "$signing_key" -m "$output/SHA256SUMS" -x "$output/SHA256SUMS.minisig" \
    -t "Tarven for Mac $version ($build)"
  minisign -V -P "$public_key" -m "$output/SHA256SUMS" -x "$output/SHA256SUMS.minisig" >/dev/null \
    || { echo "The signature does not match the Mac app's public key; nothing was uploaded." >&2; exit 1; }
  files+=("$output/SHA256SUMS.minisig")
  title="Tarven for Mac $version ($build)"
  downloads="- **Mac with Apple silicon (M1 and newer):** Tarven-$tag-macOS-arm64.dmg
- **Mac with Intel processor:** Tarven-$tag-macOS-x64.dmg

Open the disk image and drag Tarven to Applications."
fi

# Readable notes (what is new, what was fixed) come from a Markdown file, by default
# "<workspace>/Release Notes/<version>-<build>.md"; TARVEN_RELEASE_NOTES selects another file.
# The Mac updater shows this text in its update dialog. Without a file the download list is used.
notes_file=${TARVEN_RELEASE_NOTES:-"$other_root/Release Notes/$tag.md"}
if [ -n "${TARVEN_RELEASE_NOTES:-}" ] && [ ! -f "$notes_file" ]; then
  echo "Missing release notes $notes_file." >&2
  exit 1
fi
if [ -f "$notes_file" ] && grep -q '[^[:space:]]' "$notes_file"; then
  notes="$(cat "$notes_file")

## Downloads

$downloads"
else
  echo "No release notes at $notes_file; using the download list only." >&2
  notes="Tarven $version ($build).

$downloads"
fi

cd "$repository_root"
repository=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
notes="$notes

$(python3 "$repository_root/scripts/release-links.py" "$repository" --candidate "$product" "$version" "$build" "$tag")"
# Every Mac release says on whose Macs it runs and how to build it yourself.
if [ "$product" = Mac ]; then
  notes="$(cat "$repository_root/scripts/mac-registered-notice.md")

$notes"
fi
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

if [ "${TARVEN_KEEP_LOCAL_BUILDS:-0}" != 1 ]; then
  if [ "$product" = Mac ]; then rm -rf -- "$other_root/Build/Build $build" "$other_root/Build/Build $build x64"; fi
  rm -rf -- "$output"
fi
