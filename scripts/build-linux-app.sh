#!/bin/bash
# Builds Aurelia for Linux (x64): verifies it with test-linux-app.sh, publishes it self-contained
# and lays it out as installed (/usr/lib/aurelia-desktop, /usr/bin/aurelia-desktop, desktop entry,
# icon, AppStream metadata, notices). The packages (.deb, .rpm, Arch, Flatpak) are made on Linux by
# package-linux-app.sh: here when this computer is Linux, otherwise on the Linux computer named by
# AURELIA_LINUX_PACKAGE_HOST (an ssh host; AURELIA_LINUX_PACKAGE_SSH_CONFIG may name its ssh_config).
# Everything lands in Build/LinuxApp/<version>-<build>/ of the git-ignored Local workspace.
set -euo pipefail
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repository_root/scripts/workspace-paths.sh"
export DOTNET_ROOT="${DOTNET_ROOT:-$(dirname -- "$DOTNET_BIN")}" DOTNET_NOLOGO=1 DOTNET_CLI_TELEMETRY_OPTOUT=1
project="$repository_root/clients/linux/Aurelia.Linux/Aurelia.Linux.csproj"
packaging="$repository_root/clients/linux/packaging"
app_id=io.github.lucasfd3.Aurelia

# The tests also prune old builds and results first.
"$repository_root/scripts/test-linux-app.sh"

version=$("$DOTNET_BIN" msbuild "$project" -getProperty:Version)
build=$("$DOTNET_BIN" msbuild "$project" -getProperty:AureliaLinuxBuildNumber)
output="$other_root/Build/LinuxApp/$version-$build"
tree="$output/tree"
rm -rf "$output"
mkdir -p "$tree/usr/bin" "$tree/usr/share/applications" "$tree/usr/share/metainfo" \
  "$tree/usr/share/icons/hicolor/scalable/apps" "$tree/usr/share/doc/aurelia-desktop"

"$DOTNET_BIN" restore "$project" --runtime linux-x64
"$DOTNET_BIN" publish "$project" --configuration Release --runtime linux-x64 --self-contained true \
  --no-restore -p:DebugType=none --output "$tree/usr/lib/aurelia-desktop"
chmod 0755 "$tree/usr/lib/aurelia-desktop/aurelia-desktop"
ln -s ../lib/aurelia-desktop/aurelia-desktop "$tree/usr/bin/aurelia-desktop"
cp "$packaging/$app_id.desktop" "$tree/usr/share/applications/"
sed -e "s/@VERSION@/$version/" -e "s/@DATE@/$(date -u +%Y-%m-%d)/" "$packaging/$app_id.metainfo.xml" \
  > "$tree/usr/share/metainfo/$app_id.metainfo.xml"
cp "$repository_root/docs/assets/aurelia-icon.svg" "$tree/usr/share/icons/hicolor/scalable/apps/$app_id.svg"

notices="$tree/usr/share/doc/aurelia-desktop/notices"
assets_path=$("$DOTNET_BIN" msbuild "$project" -getProperty:ProjectAssetsFile)
zsh "$repository_root/scripts/collect-third-party-notices.sh" \
  "$tree/usr/lib/aurelia-desktop/aurelia-desktop.deps.json" "$assets_path" "$notices" "$packaging/THIRD_PARTY_NOTICES.md"
cp "$repository_root/docs/licenses/Inter-OFL-1.1.txt" "$notices/"
printf '%s (%s)\n' "$version" "$build" > "$tree/usr/lib/aurelia-desktop/VERSION"

# The installed layout as one archive, owned by root, without macOS metadata; the packages are made from it.
archive="$output/Aurelia-Desktop-$version-$build-linux-x64-tree.tar.gz"
if [ "$(uname -s)" = Darwin ]; then
  COPYFILE_DISABLE=1 tar --no-mac-metadata --no-xattrs --no-acls --uid 0 --gid 0 --uname root --gname root \
    -czf "$archive" -C "$tree" usr
else
  tar --owner=root:0 --group=root:0 -czf "$archive" -C "$tree" usr
fi
rm -rf "$tree"

if [ "$(uname -s)" = Linux ]; then
  bash "$repository_root/scripts/package-linux-app.sh" "$archive" "$output" "$version" "$build"
elif [ -n "${AURELIA_LINUX_PACKAGE_HOST:-}" ]; then
  ssh_options=(-o BatchMode=yes)
  [ -z "${AURELIA_LINUX_PACKAGE_SSH_CONFIG:-}" ] || ssh_options+=(-F "$AURELIA_LINUX_PACKAGE_SSH_CONFIG")
  remote_dir=".cache/aurelia-package/$version-$build"
  ssh "${ssh_options[@]}" "$AURELIA_LINUX_PACKAGE_HOST" "rm -rf '$remote_dir' && mkdir -p '$remote_dir'"
  scp -q "${ssh_options[@]}" "$archive" "$repository_root/scripts/package-linux-app.sh" \
    "$AURELIA_LINUX_PACKAGE_HOST:$remote_dir/"
  # The login shell may not be bash (fish, zsh), so the script runs under an explicit bash.
  ssh "${ssh_options[@]}" "$AURELIA_LINUX_PACKAGE_HOST" \
    "cd '$remote_dir' && bash package-linux-app.sh '${archive##*/}' out '$version' '$build'"
  scp -q "${ssh_options[@]}" "$AURELIA_LINUX_PACKAGE_HOST:$remote_dir/out/*" "$output/"
  ssh "${ssh_options[@]}" "$AURELIA_LINUX_PACKAGE_HOST" "rm -rf '$remote_dir'"
else
  echo "warning: no Linux computer for the packages; set AURELIA_LINUX_PACKAGE_HOST. Only the archive was made." >&2
fi
(cd "$output" && shasum -a 256 ./* > SHA256SUMS)
echo "Aurelia for Linux $version ($build) is in $output"
