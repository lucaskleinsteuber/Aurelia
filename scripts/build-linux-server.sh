#!/bin/bash
# Builds the Linux server downloads, one per architecture: a self-contained Tarven Server with
# its installer, systemd service, tarven command and third-party notices, packed as
# Tarven-Server-<version>-<build>-linux-<arch>.tar.gz in Build/Linux/<version>-<build>/ of the
# git-ignored Local workspace. Each package names the GitHub repository of `origin`, from whose releases
# `sudo tarven update` installs newer versions (see scripts/publish-release.sh).
set -euo pipefail
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repository_root/scripts/workspace-paths.sh"
# Old builds and test results are removed first; see prune-workspace.sh.
/bin/sh "$repository_root/scripts/prune-workspace.sh" || true
export DOTNET_ROOT="${DOTNET_ROOT:-$(dirname -- "$DOTNET_BIN")}"
project="$repository_root/src/Tarven.Server/Tarven.Server.csproj"

"$repository_root/scripts/verify-build-number.sh"
version=$("$DOTNET_BIN" msbuild "$project" -getProperty:Version)
build=$("$DOTNET_BIN" msbuild "$project" -getProperty:TarvenBuildNumber)
output="$other_root/Build/Linux/$version-$build"
origin=$(git -C "$repository_root" remote get-url origin 2>/dev/null || true)
repository=${origin#https://github.com/}
repository=${repository#git@github.com:}
repository=${repository#ssh://git@github.com/}
repository=${repository%.git}
[[ "$origin" == *github.com* && "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || repository=""
rm -rf "$output"
mkdir -p "$output"
source_commit=$(git -C "$repository_root" rev-parse HEAD)
if [ -z "$(git -C "$repository_root" status --porcelain --untracked-files=normal)" ]; then
  source_clean=true
else
  source_clean=false
fi

for arch in x64 arm64; do
  runtime="linux-$arch"
  folder="Tarven-Server-$version-linux-$arch"
  stage="$output/stage/$folder"
  mkdir -p "$stage"
  "$DOTNET_BIN" restore "$project" --runtime "$runtime"
  "$DOTNET_BIN" publish "$project" --configuration Release --runtime "$runtime" --self-contained true \
    --no-restore -p:DebugType=none --output "$stage/server"
  assets_path=$("$DOTNET_BIN" msbuild "$project" -getProperty:ProjectAssetsFile)
  zsh "$repository_root/scripts/collect-third-party-notices.sh" \
    "$stage/server/Tarven.Server.deps.json" "$assets_path" "$stage/notices"
  cp "$repository_root/LICENSE" "$stage/notices/Tarven-LICENSE.txt"
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    cp "$repository_root/packaging/linux/$file" "$stage/"
  done < "$repository_root/packaging/linux/PACKAGE_FILES"
  chmod 0755 "$stage/install.sh" "$stage/tarven" "$stage/tarven-autosleep" "$stage/tarven-wake-on-lan" \
    "$stage/server/Tarven.Server"
  printf '%s (%s)\n' "$version" "$build" > "$stage/VERSION"
  printf '%s\n' "$arch" > "$stage/ARCHITECTURE"
  [ -z "$repository" ] || printf '%s\n' "$repository" > "$stage/REPOSITORY"
  # No macOS metadata or owner names in the archive; files belong to root after installing.
  COPYFILE_DISABLE=1 tar --no-mac-metadata --no-xattrs --no-acls --uid 0 --gid 0 --uname root --gname root \
    -czf "$output/Tarven-Server-$version-$build-linux-$arch.tar.gz" -C "$output/stage" "$folder"
  # Servers from before the rename to Tarven (Aurelia) update only from a package with the old
  # name and top folder. The same package under that name: its installer takes the old
  # installation over. Kept until those servers are gone (docs/LINUX_SERVER.md).
  legacy_folder="Aurelia-Server-$version-linux-$arch"
  rm -rf "$output/stage/$legacy_folder"
  mv "$stage" "$output/stage/$legacy_folder"
  COPYFILE_DISABLE=1 tar --no-mac-metadata --no-xattrs --no-acls --uid 0 --gid 0 --uname root --gname root \
    -czf "$output/Aurelia-Server-$version-$build-linux-$arch.tar.gz" -C "$output/stage" "$legacy_folder"
done

rm -rf "$output/stage"
(cd "$output" && shasum -a 256 ./*.tar.gz > SHA256SUMS)
if [ "$(git -C "$repository_root" rev-parse HEAD)" != "$source_commit" ] \
  || [ -n "$(git -C "$repository_root" status --porcelain --untracked-files=normal)" ]; then
  source_clean=false
fi
printf '%s\n' "$source_commit" > "$output/SOURCE_COMMIT"
printf '%s\n' "$source_clean" > "$output/SOURCE_CLEAN"
echo "Linux server $version ($build) downloads are in $output"
[ -n "$repository" ] || echo "warning: origin is not a GitHub repository, so these packages cannot update themselves" >&2
