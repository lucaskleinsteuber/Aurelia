#!/bin/bash
# Called by publish-release.sh --linux-app. Publishes all four verified Linux desktop packages
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
  "$output/$base-x86_64.pkg.tar.zst" "$output/$base-x86_64.flatpak")
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
(cd "$output" && shasum -a 256 "./$base-amd64.deb" "./$base-x86_64.rpm" \
  "./$base-x86_64.pkg.tar.zst" "./$base-x86_64.flatpak" > "${checksums##*/}")
files+=("$checksums")
notes_file="${AURELIA_RELEASE_NOTES:-$other_root/Release Notes/$tag.md}"
[ -s "$notes_file" ] || { echo "Write the Linux desktop release notes to $notes_file first." >&2; exit 1; }
rendered_notes=$(mktemp)
trap 'rm -f "$rendered_notes"' EXIT
{
  cat "$notes_file"
  printf '\n\n'
  python3 "$repository_root/scripts/release-links.py" "$repository" --candidate "Linux Desktop" "$version" "$build" "$tag"
} > "$rendered_notes"
notes_file=$rendered_notes

if gh release view "$tag" >/dev/null 2>&1; then
  [ "$(gh release view "$tag" --json isDraft --jq .isDraft)" = true ] \
    || { echo "$tag is already published; published downloads are not replaced." >&2; exit 1; }
else
  gh release create "$tag" --target "$head" --latest=false --draft \
    --title "Aurelia for Linux $version ($build)" --notes-file "$notes_file"
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
jq -e '(.assets | length) == 5' "$verification/release.json" >/dev/null \
  || { echo "The draft contains unexpected downloads; it stays a draft for review." >&2; exit 1; }
gh release edit "$tag" --notes-file "$notes_file" --draft=false --latest=false
gh api "repos/$repository/releases/$release_id" > "$verification/release.json"
jq -e --arg tag "$tag" '.tag_name == $tag and .draft == false and (.assets | length) == 5' \
  "$verification/release.json" >/dev/null
echo "Published Aurelia for Linux $version ($build): $(jq -r .html_url "$verification/release.json")"
echo "Download verification receipts: $verification"
if [ "${AURELIA_KEEP_LOCAL_BUILDS:-0}" != 1 ]; then
  rm -rf -- "$output"
  echo "Removed the local build output; the verified release is on GitHub."
fi
