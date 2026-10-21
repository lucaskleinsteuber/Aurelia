#!/bin/sh
# Checks the desktop app on a real Windows PC or virtual machine over SSH, where Wine cannot, with
# synthetic data only: the server's Windows file code with real links, the desktop tests against
# the real Windows server build (HTTPS on 127.0.0.1, owner setup, pairing, recovery, hosting), and
# with --installer a silent install, the firewall rule and an uninstall that keeps data (for test
# machines only). Everything is copied to a temporary folder there and removed afterwards.
# Usage: scripts/test-desktop-windows.sh user@host [arm64|x64] [--installer]
set -eu
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repository_root/scripts/workspace-paths.sh"
export DOTNET_ROOT="${DOTNET_ROOT:-$(dirname -- "$DOTNET_BIN")}"
target=${1:?Pass user@host of the Windows machine.}
arch=${2:-arm64}
check_installer=${3:-}
key=${AURELIA_WINDOWS_SSH_KEY:-"$other_root/WindowsVM/aurelia-vm-key"}
known_hosts="$other_root/WindowsVM/known_hosts"
remote() { ssh -i "$key" -o "UserKnownHostsFile=$known_hosts" -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=15 "$target" "$@"; }
copy() { scp -q -i "$key" -o "UserKnownHostsFile=$known_hosts" -o StrictHostKeyChecking=accept-new -o BatchMode=yes "$@"; }

stage="$other_root/Build/WindowsTest/win-$arch"
rm -rf "$stage"
mkdir -p "$stage"
"$DOTNET_BIN" publish "$repository_root/src/Aurelia.Server/Aurelia.Server.csproj" --configuration Release --runtime "win-$arch" \
  --self-contained true -p:DebugType=none --output "$stage/server" >/dev/null
"$DOTNET_BIN" publish "$repository_root/tools/Aurelia.Server.WindowsProbe" --configuration Release --runtime "win-$arch" \
  --self-contained true -p:DebugType=none --output "$stage/probe" >/dev/null
"$DOTNET_BIN" publish "$repository_root/clients/desktop/Aurelia.Desktop.Tests" --configuration Release --runtime "win-$arch" \
  --self-contained true -p:DebugType=none --output "$stage/tests" >/dev/null
cp "$repository_root/scripts/windows/test-desktop.ps1" "$repository_root/scripts/windows/test-installer.ps1" "$stage/"
setup_argument=""
if [ "$check_installer" = --installer ]; then
  props="$repository_root/clients/desktop/Directory.Build.props"
  version=$(sed -n 's:.*<Version>\([^<]*\)</Version>.*:\1:p' "$props")
  build=$(sed -n 's:.*<AureliaDesktopBuildNumber>\([0-9]*\)</AureliaDesktopBuildNumber>.*:\1:p' "$props")
  setup="$other_root/Build/Desktop/$version-$build/Aurelia-$version-$build-Setup-$arch.exe"
  [ -f "$setup" ] || { echo "Build the installer first with scripts/build-desktop.sh." >&2; exit 1; }
  cp "$setup" "$stage/"
  setup_argument="-Setup $(basename "$setup") -Version $version -Build $build"
fi
(cd "$stage" && tar -czf "../win-$arch.tgz" .)

run="AureliaTest-$(date -u +%Y%m%dT%H%M%SZ)"
copy "$stage/../win-$arch.tgz" "$target:$run.tgz"
remote "mkdir $run && tar -xzf $run.tgz -C $run && del $run.tgz"
status=0
remote "powershell -NoProfile -ExecutionPolicy Bypass -File $run\\test-desktop.ps1 $setup_argument" || status=$?
remote "rmdir /s /q $run" || true
rm -rf "$stage" "$stage/../win-$arch.tgz"
exit "$status"
