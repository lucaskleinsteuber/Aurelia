#!/bin/bash
# Called by publish-release.sh --linux-app. Publishes the verified Linux desktop packages for x64
# (deb, rpm, Arch, Flatpak) and arm64 (deb, rpm, Arch)
# with an independent linux-app-<version>-<build> tag, never as the Mac "latest" release.
# Uploads stay in a draft until GitHub reports every asset uploaded and the downloaded bytes
# match the local SHA-256 values. No source, version, or Git history is changed by this script.
set -euo pipefail
[ "$#" -eq 0 ] || { echo "Usage: publish-release.sh --linux-app" >&2; exit 1; }
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repository_root/scripts/workspace-paths.sh"
/bin/sh "$repository_root/scripts/prune-workspace.sh" || true
project="$repository_root/clients/linux/Aurelia.Linux/Aurelia.Linux.csproj"
version=$("$DOTNET_BIN" msbuild "$project" -getProperty:Version)
build=$("$DOTNET_BIN" msbuild "$project" -getProperty:AureliaLinuxBuildNumber)
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build" =~ ^[0-9]+$ ]] \
  || { echo "Use a MAJOR.MINOR.PATCH version and numeric build." >&2; exit 1; }
tag="linux-app-$version-$build"
output="$other_root/Build/LinuxApp/$version-$build"
base="Aurelia-Desktop-$version-$build"
files=("$output/$base-amd64.deb" "$output/$base-x86_64.rpm"
  "$output/$base-x86_64.pkg.tar.zst" "$output/$base-x86_64.flatpak"
  "$output/$base-arm64.deb" "$output/$base-aarch64.rpm" "$output/$base-aarch64.pkg.tar.zst")
for file in "${files[@]}"; do
  [ -s "$file" ] || { echo "Missing $file; build and verify every package first." >&2; exit 1; }
done
cd "$repository_root"
[ -z "$(git status --porcelain --untracked-files=normal)" ] \
  || { echo "Commit all source changes before publishing." >&2; exit 1; }
head=$(git rev-parse HEAD)
git fetch --quiet origin main
git merge-base --is-ancestor "$head" origin/main \
  || { echo "Push this source commit to origin/main before publishing." >&2; exit 1; }
[ "$(cat "$output/SOURCE_COMMIT")" = "$head" ] && [ "$(cat "$output/SOURCE_CLEAN")" = true ] \
  || { echo "Rebuild the packages from this committed source before publishing." >&2; exit 1; }
repository=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
# An existing tag may not be moved or reused for another commit.
tag_hash=$(git ls-remote origin "refs/tags/$tag" "refs/tags/$tag^{}" | tail -1 | cut -f1)
[ -z "$tag_hash" ] || [ "$tag_hash" = "$head" ] \
  || { echo "The published tag $tag points at another commit." >&2; exit 1; }

checksums="$output/SHA256SUMS"
(cd "$output" && shasum -a 256 $(for file in "${files[@]}"; do printf './%s ' "${file##*/}"; done) > "${checksums##*/}")
files+=("$checksums")
# The app installs nothing whose SHA256SUMS lacks the owner's minisign signature
# (docs/LINUX_UPDATE_SIGNING.md). The secret key stays on this Mac and never goes to GitHub.
command -v minisign >/dev/null \
  || { echo "Install minisign (brew install minisign) to sign the release." >&2; exit 1; }
signing_key="${AURELIA_MINISIGN_SECRET_KEY:-$HOME/.minisign/aurelia-linux.key}"
[ -s "$signing_key" ] \
  || { echo "Missing the minisign secret key $signing_key; see docs/LINUX_UPDATE_SIGNING.md." >&2; exit 1; }
public_key=$(sed -n 's/.*SigningPublicKey = "\([A-Za-z0-9+\/=]*\)";.*/\1/p' \
  "$repository_root/clients/linux/Aurelia.Linux.Core/Updates/UpdateFeed.cs")
[ -n "$public_key" ] \
  || { echo "UpdateFeed.SigningPublicKey is empty; the app could not check this signature." >&2; exit 1; }
rm -f "$checksums.minisig"
minisign -S -s "$signing_key" -m "$checksums" -x "$checksums.minisig" \
  -t "Aurelia for Linux $version ($build)"
# Check with the exact key the published app carries, before anything is uploaded.
minisign -V -P "$public_key" -m "$checksums" -x "$checksums.minisig" >/dev/null \
  || { echo "The signature does not match the app's public key; nothing was uploaded." >&2; exit 1; }
files+=("$checksums.minisig")
notes_file="${AURELIA_RELEASE_NOTES:-$other_root/Release Notes/$tag.md}"
[ -s "$notes_file" ] || { echo "Write the Linux desktop release notes to $notes_file first." >&2; exit 1; }
rendered_notes=$(mktemp)
trap 'rm -f "$rendered_notes"' EXIT
beta=${AURELIA_RELEASE_BETA:-false}
title="Aurelia for Linux $version ($build)"
if [ "$beta" = true ]; then title="$title Beta"; fi
{
  if [ "$beta" = true ]; then cat "$repository_root/scripts/beta-notice.md"; printf '\n'; fi
  cat "$notes_file"
  printf '\n\n'
  python3 "$repository_root/scripts/release-links.py" "$repository" --candidate "Linux Desktop" "$version" "$build" "$tag"
} > "$rendered_notes"
notes_file=$rendered_notes

if gh release view "$tag" >/dev/null 2>&1; then
  [ "$(gh release view "$tag" --json isDraft --jq .isDraft)" = true ] \
    || { echo "$tag is already published; published downloads are not replaced." >&2; exit 1; }
else
  gh release create "$tag" --target "$head" --latest=false --prerelease="$beta" --draft \
    --title "$title" --notes-file "$notes_file"
fi
for file in "${files[@]}"; do
  gh release upload "$tag" "$file" --clobber || GODEBUG=http2client=0 gh release upload "$tag" "$file" --clobber
done

verification="$other_root/Test Results/LinuxAppRelease-$tag-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$verification"
# A draft may not have a Git tag yet; GitHub's /releases/tags endpoint then returns 404.
# gh release view also resolves these untagged drafts and exposes their stable REST URL.
release_id=$(gh release view "$tag" --json apiUrl --jq '.apiUrl | split("/") | last')
[[ "$release_id" =~ ^[0-9]+$ ]] \
  || { echo "GitHub did not return a numeric release id; the release stays a draft." >&2; exit 1; }
gh api "repos/$repository/releases/$release_id" > "$verification/release.json"
for file in "${files[@]}"; do
  name=${file##*/}
  size=$(wc -c < "$file" | tr -d '[:space:]')
  asset=$(jq -c --arg name "$name" --argjson size "$size" \
    '.assets[] | select(.name == $name and .state == "uploaded" and .size == $size)' "$verification/release.json")
  [ -n "$asset" ] || { echo "GitHub has not uploaded $name with the correct size; the release stays a draft." >&2; exit 1; }
  gh release download "$tag" --pattern "$name" --dir "$verification" --clobber
  [ "$(shasum -a 256 "$file" | cut -d ' ' -f1)" = "$(shasum -a 256 "$verification/$name" | cut -d ' ' -f1)" ] \
    || { echo "$name failed downloaded SHA-256 verification; the release stays a draft." >&2; exit 1; }
  printf '%s  %s bytes  %s\n' "$name" "$size" "$(shasum -a 256 "$verification/$name" | cut -d ' ' -f1)" \
    >> "$verification/verified-downloads.txt"
  case "$name" in *.deb|*.rpm|*.pkg.tar.zst|*.flatpak) rm -f -- "$verification/$name" ;; esac
done
jq -e '(.assets | length) == 9' "$verification/release.json" >/dev/null \
  || { echo "The draft contains unexpected downloads; it stays a draft for review." >&2; exit 1; }
gh release edit "$tag" --notes-file "$notes_file" --draft=false --latest=false --prerelease="$beta"
gh api "repos/$repository/releases/$release_id" > "$verification/release.json"
jq -e --arg tag "$tag" '.tag_name == $tag and .draft == false and (.assets | length) == 9' \
  "$verification/release.json" >/dev/null
echo "Published Aurelia for Linux $version ($build): $(jq -r .html_url "$verification/release.json")"
echo "Download verification receipts: $verification"
if [ "${AURELIA_KEEP_LOCAL_BUILDS:-0}" != 1 ]; then
  rm -rf -- "$output"
  echo "Removed the local build output; the verified release is on GitHub."
fi
