#!/bin/bash
# Builds the Linux server downloads, one per architecture: a self-contained Aurelia Server with
# its installer, systemd service, aurelia command and third-party notices, packed as
# Aurelia-Server-<version>-<build>-linux-<arch>.tar.gz in Build/Linux/<version>-<build>/ of the
# external workspace.
set -euo pipefail
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repository_root/scripts/workspace-paths.sh"
export DOTNET_ROOT="${DOTNET_ROOT:-$(dirname -- "$DOTNET_BIN")}"
project="$repository_root/src/Aurelia.Server/Aurelia.Server.csproj"

"$repository_root/scripts/verify-build-number.sh"
version=$("$DOTNET_BIN" msbuild "$project" -getProperty:Version)
build=$("$DOTNET_BIN" msbuild "$project" -getProperty:AureliaBuildNumber)
output="$other_root/Build/Linux/$version-$build"
rm -rf "$output"
mkdir -p "$output"

for arch in x64 arm64; do
  runtime="linux-$arch"
  folder="Aurelia-Server-$version-linux-$arch"
  stage="$output/stage/$folder"
  mkdir -p "$stage"
  "$DOTNET_BIN" restore "$project" --runtime "$runtime"
  "$DOTNET_BIN" publish "$project" --configuration Release --runtime "$runtime" --self-contained true \
    --no-restore -p:DebugType=none --output "$stage/server"
  assets_path=$("$DOTNET_BIN" msbuild "$project" -getProperty:ProjectAssetsFile)
  zsh "$repository_root/scripts/collect-third-party-notices.sh" \
    "$stage/server/Aurelia.Server.deps.json" "$assets_path" "$stage/notices"
  for file in install.sh aurelia aurelia.service aurelia-autosleep aurelia-sleep-settings aurelia-autosleep.service \
    aurelia-autosleep.timer aurelia-wake-on-lan aurelia-wake-on-lan.service aurelia-start.socket \
    aurelia-start.service; do
    cp "$repository_root/packaging/linux/$file" "$stage/"
  done
  chmod 0755 "$stage/install.sh" "$stage/aurelia" "$stage/aurelia-autosleep" "$stage/aurelia-wake-on-lan" \
    "$stage/server/Aurelia.Server"
  printf '%s (%s)\n' "$version" "$build" > "$stage/VERSION"
  printf '%s\n' "$arch" > "$stage/ARCHITECTURE"
  # No macOS metadata or owner names in the archive; files belong to root after installing.
  COPYFILE_DISABLE=1 tar --no-mac-metadata --no-xattrs --no-acls --uid 0 --gid 0 --uname root --gname root \
    -czf "$output/Aurelia-Server-$version-$build-linux-$arch.tar.gz" -C "$output/stage" "$folder"
done

rm -rf "$output/stage"
(cd "$output" && shasum -a 256 ./*.tar.gz > SHA256SUMS)
echo "Linux server $version ($build) downloads are in $output"
