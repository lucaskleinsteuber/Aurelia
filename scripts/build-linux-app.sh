#!/bin/bash
# Builds Tarven for Linux for x64 and arm64 (TARVEN_LINUX_ARCHES may choose one): verifies it with test-linux-app.sh, publishes it self-contained
# and lays it out as installed (/usr/lib/tarven-desktop, /usr/bin/tarven-desktop, desktop entry,
# icon, AppStream metadata, notices). The packages (.deb, .rpm, Arch, Flatpak) are made on Linux by
# package-linux-app.sh: here when this computer is Linux, otherwise on the Linux computer named by
# TARVEN_LINUX_PACKAGE_HOST (an ssh host; TARVEN_LINUX_PACKAGE_SSH_CONFIG may name its ssh_config).
# With TARVEN_LINUX_PACKAGE_DOCKER=1 that host needs only Docker (package-linux-app-in-docker.sh).
# Everything lands in Build/LinuxApp/<version>-<build>/ of the git-ignored Local workspace.
set -euo pipefail
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repository_root/scripts/workspace-paths.sh"
export DOTNET_ROOT="${DOTNET_ROOT:-$(dirname -- "$DOTNET_BIN")}" DOTNET_NOLOGO=1 DOTNET_CLI_TELEMETRY_OPTOUT=1
project="$repository_root/clients/linux/Tarven.Linux/Tarven.Linux.csproj"
packaging="$repository_root/clients/linux/packaging"
app_id=org.tarven.Tarven
package_formats="${TARVEN_LINUX_PACKAGE_FORMATS:-deb rpm arch flatpak}"
normalized_formats=''
for package_format in $package_formats; do
  case "$package_format" in deb|rpm|arch|flatpak) ;; *) echo "Unknown package format: $package_format" >&2; exit 1 ;; esac
  normalized_formats="$normalized_formats $package_format"
done
package_formats=${normalized_formats# }
linux_arches="${TARVEN_LINUX_ARCHES:-x64 arm64}"
for linux_arch in $linux_arches; do
  case "$linux_arch" in x64|arm64) ;; *) echo "Unknown architecture: $linux_arch (x64 or arm64)" >&2; exit 1 ;; esac
done

# The tests also prune old builds and results first.
"$repository_root/scripts/test-linux-app.sh"

version=$("$DOTNET_BIN" msbuild "$project" -getProperty:Version)
build=$("$DOTNET_BIN" msbuild "$project" -getProperty:TarvenLinuxBuildNumber)
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build" =~ ^[0-9]+$ ]] \
  || { echo "The Linux app must have a MAJOR.MINOR.PATCH version and numeric build." >&2; exit 1; }
output="$other_root/Build/LinuxApp/$version-$build"
rm -rf "$output"
mkdir -p "$output"
git -C "$repository_root" rev-parse HEAD > "$output/SOURCE_COMMIT"
if [ -z "$(git -C "$repository_root" status --porcelain --untracked-files=normal)" ]; then
  echo true > "$output/SOURCE_CLEAN"
else
  echo false > "$output/SOURCE_CLEAN"
fi

for linux_arch in $linux_arches; do
  tree="$output/tree-$linux_arch"
  rm -rf "$tree"
  mkdir -p "$tree/usr/bin" "$tree/usr/share/applications" "$tree/usr/share/metainfo" \
    "$tree/usr/share/icons/hicolor/scalable/apps" "$tree/usr/share/doc/tarven-desktop"
  "$DOTNET_BIN" restore "$project" --runtime linux-$linux_arch
  "$DOTNET_BIN" publish "$project" --configuration Release --runtime linux-$linux_arch --self-contained true \
    --no-restore -p:DebugType=none --output "$tree/usr/lib/tarven-desktop"
  chmod 0755 "$tree/usr/lib/tarven-desktop/tarven-desktop"
  # The server for "Set Up This PC" comes with the app; the app starts it on demand.
  server_project="$repository_root/src/Tarven.Server/Tarven.Server.csproj"
  "$DOTNET_BIN" restore "$server_project" --runtime linux-$linux_arch
  "$DOTNET_BIN" publish "$server_project" --configuration Release --runtime linux-$linux_arch --self-contained true \
    --no-restore -p:DebugType=none --output "$tree/usr/lib/tarven-desktop/server"
  chmod 0755 "$tree/usr/lib/tarven-desktop/server/Tarven.Server"
  ln -s ../lib/tarven-desktop/tarven-desktop "$tree/usr/bin/tarven-desktop"
  cp "$packaging/$app_id.desktop" "$tree/usr/share/applications/"
  sed -e "s/@VERSION@/$version/" -e "s/@DATE@/$(date -u +%Y-%m-%d)/" "$packaging/$app_id.metainfo.xml" \
    > "$tree/usr/share/metainfo/$app_id.metainfo.xml"
  cp "$repository_root/docs/assets/tarven-icon.svg" "$tree/usr/share/icons/hicolor/scalable/apps/$app_id.svg"

  notices="$tree/usr/share/doc/tarven-desktop/notices"
  assets_path=$("$DOTNET_BIN" msbuild "$project" -getProperty:ProjectAssetsFile)
  zsh "$repository_root/scripts/collect-third-party-notices.sh" \
    "$tree/usr/lib/tarven-desktop/tarven-desktop.deps.json" "$assets_path" "$notices" "$packaging/THIRD_PARTY_NOTICES.md"
  server_assets=$("$DOTNET_BIN" msbuild "$server_project" -getProperty:ProjectAssetsFile)
  zsh "$repository_root/scripts/collect-third-party-notices.sh" \
    "$tree/usr/lib/tarven-desktop/server/Tarven.Server.deps.json" "$server_assets" "$notices/server"
  cp "$repository_root/docs/licenses/Inter-OFL-1.1.txt" "$notices/"
  mkdir -p "$tree/usr/share/licenses/tarven-desktop"
  cp "$repository_root/LICENSE" "$tree/usr/share/licenses/tarven-desktop/LICENSE"
  printf '%s (%s)\n' "$version" "$build" > "$tree/usr/lib/tarven-desktop/VERSION"
  cp "$output/SOURCE_COMMIT" "$tree/usr/lib/tarven-desktop/SOURCE_COMMIT"

  # The installed layout as one archive, owned by root, without macOS metadata; the packages are made from it.
  archive="$output/Tarven-Desktop-$version-$build-linux-$linux_arch-tree.tar.gz"
  if [ "$(uname -s)" = Darwin ]; then
    COPYFILE_DISABLE=1 tar --no-mac-metadata --no-xattrs --no-acls --uid 0 --gid 0 --uname root --gname root \
      -czf "$archive" -C "$tree" usr
  else
    tar --owner=root:0 --group=root:0 -czf "$archive" -C "$tree" usr
  fi
  rm -rf "$tree"

  if [ "$(uname -s)" = Linux ]; then
    bash "$repository_root/scripts/package-linux-app.sh" "$archive" "$output" "$version" "$build" "$linux_arch"
  elif [ -n "${TARVEN_LINUX_PACKAGE_HOST:-}" ]; then
    ssh_options=(-o BatchMode=yes)
    [ -z "${TARVEN_LINUX_PACKAGE_SSH_CONFIG:-}" ] || ssh_options+=(-F "$TARVEN_LINUX_PACKAGE_SSH_CONFIG")
    remote_dir=".cache/tarven-package/$version-$build"
    # TARVEN_LINUX_PACKAGE_DOCKER=1: the host has Docker instead of the packaging tools (the owner's
    # server while the laptop is off); the packages are made in a throwaway Arch Linux container there.
    package_runner=package-linux-app.sh
    [ "${TARVEN_LINUX_PACKAGE_DOCKER:-0}" = 1 ] && package_runner=package-linux-app-in-docker.sh
    ssh "${ssh_options[@]}" "$TARVEN_LINUX_PACKAGE_HOST" "rm -rf '$remote_dir' && mkdir -p '$remote_dir/packaging'"
    scp -q "${ssh_options[@]}" "$archive" "$repository_root/scripts/package-linux-app.sh" \
      "$repository_root/scripts/package-linux-app-in-docker.sh" "$TARVEN_LINUX_PACKAGE_HOST:$remote_dir/"
    scp -qr "${ssh_options[@]}" "$packaging/flatpak" "$TARVEN_LINUX_PACKAGE_HOST:$remote_dir/packaging/"
    # The login shell may not be bash (fish, zsh), so the script runs under an explicit bash.
    ssh "${ssh_options[@]}" "$TARVEN_LINUX_PACKAGE_HOST" \
      "cd '$remote_dir' && TARVEN_LINUX_PACKAGE_FORMATS='$package_formats' bash $package_runner '${archive##*/}' out '$version' '$build' '$linux_arch'"
    scp -q "${ssh_options[@]}" "$TARVEN_LINUX_PACKAGE_HOST:$remote_dir/out/*" "$output/"
    ssh "${ssh_options[@]}" "$TARVEN_LINUX_PACKAGE_HOST" "rm -rf '$remote_dir' && rmdir .cache/tarven-package 2>/dev/null; true"
  else
    echo "warning: no Linux computer for the packages; set TARVEN_LINUX_PACKAGE_HOST. Only the archive was made." >&2
  fi
done
(cd "$output" && shasum -a 256 ./* > SHA256SUMS)
echo "Tarven for Linux $version ($build) is in $output"
