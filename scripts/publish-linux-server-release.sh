#!/bin/bash
# Publishes the Linux server downloads that scripts/build-linux-server.sh made for the current
# version as a GitHub Release of `origin`, tagged <version>-<build> at the pushed HEAD, for
# `sudo aurelia update` to install. A release is public to everyone who can see the repository:
# run this only with the owner's approval for that version. An existing release of the same tag
# gets the downloads added or replaced.
set -euo pipefail
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repository_root/scripts/workspace-paths.sh"
project="$repository_root/src/Aurelia.Server/Aurelia.Server.csproj"

version=$("$DOTNET_BIN" msbuild "$project" -getProperty:Version)
build=$("$DOTNET_BIN" msbuild "$project" -getProperty:AureliaBuildNumber)
tag="$version-$build"
output="$other_root/Build/Linux/$tag"
files=("$output/Aurelia-Server-$tag-linux-x64.tar.gz" "$output/Aurelia-Server-$tag-linux-arm64.tar.gz"
  "$output/SHA256SUMS")
for file in "${files[@]}"; do
  [ -f "$file" ] || { echo "Missing $file; run scripts/build-linux-server.sh first." >&2; exit 1; }
done
(cd "$output" && shasum -a 256 -c SHA256SUMS >/dev/null) || { echo "The downloads do not match SHA256SUMS." >&2; exit 1; }

head=$(git -C "$repository_root" rev-parse HEAD)
git -C "$repository_root" fetch --quiet origin
git -C "$repository_root" merge-base --is-ancestor "$head" origin/main \
  || { echo "Push HEAD to origin/main before publishing it." >&2; exit 1; }

cd "$repository_root"
if gh release view "$tag" >/dev/null 2>&1; then
  gh release upload "$tag" "${files[@]}" --clobber
else
  gh release create "$tag" "${files[@]}" --target "$head" --latest \
    --title "Aurelia $version ($build)" \
    --notes "Aurelia Server $version ($build) for Linux. Installed servers update with: sudo aurelia update"
fi
echo "Published the Linux server downloads of $version ($build) as release $tag."
