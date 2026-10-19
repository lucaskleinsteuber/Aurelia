#!/bin/sh
# Builds the desktop client for Windows x64 and ARM64 (and this Mac) without a Windows PC.
# Each build is a self-contained Aurelia.exe with its VLC and, in server/, the bundled Aurelia
# Server it hosts, so neither .NET nor VLC needs to be installed. The Windows builds carry their
# third-party notices and become installers (scripts/make-desktop-installer.sh, which needs
# CrossOver; AURELIA_DESKTOP_INSTALLERS=0 skips them).
set -eu
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repository_root/scripts/workspace-paths.sh"
export DOTNET_ROOT="${DOTNET_ROOT:-$(dirname -- "$DOTNET_BIN")}"
project="$repository_root/clients/desktop/Aurelia.Desktop/Aurelia.Desktop.csproj"
server_project="$repository_root/src/Aurelia.Server/Aurelia.Server.csproj"
props="$repository_root/clients/desktop/Directory.Build.props"
version=$(sed -n 's:.*<Version>\([^<]*\)</Version>.*:\1:p' "$props")
build=$(sed -n 's:.*<AureliaDesktopBuildNumber>\([0-9]*\)</AureliaDesktopBuildNumber>.*:\1:p' "$props")
output_root="$other_root/Build/Desktop/$version-$build"
build_root=${AURELIA_BUILD_ROOT:-"$other_root/Build"}
overview="$repository_root/clients/desktop/THIRD_PARTY_NOTICES.md"
rm -rf "$output_root"
mkdir -p "$output_root"
for rid in win-x64 win-arm64 osx-arm64; do
  "$DOTNET_BIN" publish "$project" --configuration Release --runtime "$rid" --self-contained true \
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true \
    -p:DebugType=none --output "$output_root/$rid"
  # The same server the Mac app bundles, published for this platform beside the app.
  "$DOTNET_BIN" publish "$server_project" --configuration Release --runtime "$rid" --self-contained true \
    -p:DebugType=none --output "$output_root/$rid/server"
  case "$rid" in
    win-*)
      # Read from the published dependency graphs of the app and its server.
      notices="$output_root/$rid/Third-Party Notices"
      zsh "$repository_root/scripts/collect-third-party-notices.sh" "$build_root/bin/Aurelia.Desktop/Release/net10.0/$rid/Aurelia.deps.json" \
        "$("$DOTNET_BIN" msbuild "$project" -getProperty:ProjectAssetsFile)" "$notices/App" "$overview"
      zsh "$repository_root/scripts/collect-third-party-notices.sh" "$output_root/$rid/server/Aurelia.Server.deps.json" \
        "$("$DOTNET_BIN" msbuild "$server_project" -getProperty:ProjectAssetsFile)" "$notices/Server" "$overview"
      cp "$overview" "$notices/README.md"
      cp "$repository_root/docs/licenses/LGPL-2.1.txt" "$notices/LibVLC-LGPL-2.1.txt"
      cp "$repository_root/docs/licenses/Inter-OFL-1.1.txt" "$notices/Inter-OFL-1.1.txt"
      ;;
  esac
done
# Graphics packages ship native debug symbols; the app does not need them.
find "$output_root" -name '*.pdb' -delete
if [ "${AURELIA_DESKTOP_INSTALLERS:-1}" != 0 ]; then
  sh "$repository_root/scripts/make-desktop-installer.sh" "$output_root" "$version" "$build"
fi
echo "Desktop $version ($build) builds are in $output_root"
