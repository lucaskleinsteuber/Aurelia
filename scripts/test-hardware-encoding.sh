#!/bin/bash
# Checks the real video chips of a Linux computer (Nvidia NVENC, Intel Quick Sync, VA-API) with
# invented test pictures: copies the source tree without Local/ and .git to a temporary folder there,
# runs the HardwareEncoding test category with that computer's ffmpeg and .NET SDK, and removes the
# folder again. Nothing is installed and no media is read.
# Usage: test-hardware-encoding.sh <ssh host>   (AURELIA_LINUX_PACKAGE_SSH_CONFIG as for building)
set -euo pipefail
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
host=${1:?Provide the ssh host.}
ssh_options=(-o BatchMode=yes)
[ -z "${AURELIA_LINUX_PACKAGE_SSH_CONFIG:-}" ] || ssh_options+=(-F "$AURELIA_LINUX_PACKAGE_SSH_CONFIG")

# The remote login shell may not be bash (fish, for example), so every command runs in bash.
remote_bash() { ssh "${ssh_options[@]}" "$host" "bash -c $(printf '%q' "$1")"; }

remote=$(remote_bash 'mktemp -d "${TMPDIR:-/tmp}/aurelia-hardware.XXXXXX"')
cleanup() { remote_bash "rm -rf '$remote'" || true; }
trap cleanup EXIT

# A .NET SDK in ~/.cache/aurelia-dotnet (dotnet-install.sh --install-dir) is used when none is on the path.
dotnet='$(command -v dotnet || echo "$HOME/.cache/aurelia-dotnet/dotnet")'
remote_bash "[ -x \"$dotnet\" ] && command -v ffmpeg >/dev/null" \
  || { echo "$host needs the .NET SDK and ffmpeg for this test." >&2; exit 1; }
remote_bash 'ffmpeg -hide_banner -encoders 2>/dev/null | grep -E "h264_(nvenc|qsv|vaapi)" || true; ls /dev/dri 2>/dev/null || true'

git -C "$repository_root" archive --format=tar HEAD -- Aurelia.slnx Directory.Build.props Directory.Packages.props global.json NuGet.Config src tests clients/macos/AureliaTests/Fixtures \
  | remote_bash "tar -x -C '$remote'"
remote_bash "cd '$remote' && AURELIA_HARDWARE_TESTS=1 DOTNET_CLI_TELEMETRY_OPTOUT=1 \"$dotnet\" test tests/Aurelia.Server.Tests --filter Category=HardwareEncoding --logger 'console;verbosity=normal'"
