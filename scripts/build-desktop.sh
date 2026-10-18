#!/bin/sh
# Builds the desktop client for Windows x64 and ARM64 (and this Mac) without a Windows PC.
# Each Windows build is one self-contained Aurelia.exe that needs no .NET installation.
set -eu
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repository_root/scripts/workspace-paths.sh"
export DOTNET_ROOT="${DOTNET_ROOT:-$(dirname -- "$DOTNET_BIN")}"
project="$repository_root/clients/desktop/Aurelia.Desktop/Aurelia.Desktop.csproj"
props="$repository_root/clients/desktop/Directory.Build.props"
version=$(sed -n 's:.*<Version>\([^<]*\)</Version>.*:\1:p' "$props")
build=$(sed -n 's:.*<AureliaDesktopBuildNumber>\([0-9]*\)</AureliaDesktopBuildNumber>.*:\1:p' "$props")
output_root="$other_root/Build/Desktop/$version-$build"
rm -rf "$output_root"
mkdir -p "$output_root"
for rid in win-x64 win-arm64 osx-arm64; do
  "$DOTNET_BIN" publish "$project" --configuration Release --runtime "$rid" --self-contained true \
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true \
    -p:DebugType=none --output "$output_root/$rid"
done
# Graphics packages ship native debug symbols; the app does not need them.
find "$output_root" -name '*.pdb' -delete
for rid in win-x64 win-arm64; do
  (cd "$output_root/$rid" && zip -q -r "$output_root/Aurelia-$version-$build-$rid.zip" .)
done
echo "Desktop $version ($build) builds are in $output_root"
