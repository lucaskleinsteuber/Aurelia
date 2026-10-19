#!/bin/sh
# Makes the Windows installers (x64 and ARM64) from the output of scripts/build-desktop.sh with
# Inno Setup 7.1.0 under CrossOver's Wine on this Mac. Inno Setup is downloaded once from its
# official GitHub release, checked against its pinned SHA-256 and installed into its own Wine prefix
# in the workspace, never into CrossOver's bottles. The compiler runs without a window.
set -eu
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repository_root/scripts/workspace-paths.sh"
output_root=${1:?Pass the folder scripts/build-desktop.sh wrote.}
version=${2:?Pass the app version.}
build=${3:?Pass the build number.}
crossover=${AURELIA_CROSSOVER_ROOT:-/Applications/CrossOver.app/Contents/SharedSupport/CrossOver}
[ -x "$crossover/bin/wineloader" ] || { echo "CrossOver's Wine was not found at $crossover; the Windows installers need it." >&2; exit 2; }

cache="$other_root/Package Cache/InnoSetup"
download="$cache/innosetup-7.1.0-x64.exe"
checksum=0362a383ed217d4c4239b5933866dd96d3eb2102737da92f80f6057a4b40df2f
export CX_ROOT="$crossover" WINEPREFIX="$cache/prefix" WINEDEBUG=-all WINESERVER="$crossover/bin/wineserver"
# No browser engine, menu entries or crash debugger windows.
export WINEDLLOVERRIDES="mshtml=;winemenubuilder.exe=d;winedbg.exe=d"
compiler="$WINEPREFIX/drive_c/InnoSetup/ISCC.exe"
cleanup() { "$crossover/bin/wineserver" -k 2>/dev/null || true; [ -z "${icons:-}" ] || rm -rf "$icons"; }
trap cleanup EXIT

if [ ! -f "$compiler" ]; then
  mkdir -p "$cache"
  if [ ! -f "$download" ]; then
    curl -sSfL -o "$download.part" "https://github.com/jrsoftware/issrc/releases/download/is-7_1_0/innosetup-7.1.0-x64.exe"
    mv "$download.part" "$download"
  fi
  if ! echo "$checksum  $download" | shasum -a 256 -c - >/dev/null; then
    rm -f "$download"
    echo "The Inno Setup download does not match its pinned checksum." >&2
    exit 1
  fi
  "$crossover/bin/wineloader" "$download" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CURRENTUSER /NOICONS '/DIR=C:\InnoSetup' >/dev/null 2>&1
  "$crossover/bin/wineserver" -w
  [ -f "$compiler" ] || { echo "Inno Setup could not be installed into $WINEPREFIX." >&2; exit 1; }
fi

to_windows() { printf 'Z:%s' "$1" | tr '/' '\\'; }
# The wizard shows the app icon; its 128 and 256 pixel images come from the app's .ico.
icons=$(mktemp -d)
python3 -I - "$repository_root/clients/desktop/Aurelia.Desktop/Assets/aurelia.ico" "$icons" <<'PYTHON'
import struct, sys, pathlib
data = pathlib.Path(sys.argv[1]).read_bytes()
for index in range(struct.unpack("<HHH", data[:6])[2]):
    width, _, _, _, _, _, length, offset = struct.unpack("<BBBBHHII", data[6 + 16 * index:22 + 16 * index])
    if (width or 256) in (128, 256):
        pathlib.Path(sys.argv[2], f"aurelia-icon-{width or 256}.png").write_bytes(data[offset:offset + length])
PYTHON
for arch in x64 arm64; do
  [ -f "$output_root/win-$arch/Aurelia.exe" ] || { echo "Build win-$arch first with scripts/build-desktop.sh." >&2; exit 1; }
  "$crossover/bin/wineloader" "$compiler" -q \
    "/DAppVersion=$version" "/DAppBuild=$build" "/DArch=$arch" \
    "/DSourceDir=$(to_windows "$output_root/win-$arch")" "/DOutputDir=$(to_windows "$output_root")" \
    "/DIconFile=$(to_windows "$repository_root/clients/desktop/Aurelia.Desktop/Assets/aurelia.ico")" \
    "/DWizardImage=$(to_windows "$icons/aurelia-icon-128.png"),$(to_windows "$icons/aurelia-icon-256.png")" \
    "$(to_windows "$repository_root/clients/desktop/Installer/Aurelia.iss")"
  [ -f "$output_root/Aurelia-$version-$build-Setup-$arch.exe" ] || { echo "The $arch installer was not created." >&2; exit 1; }
done
echo "Installers: $output_root/Aurelia-$version-$build-Setup-x64.exe and -arm64.exe"
