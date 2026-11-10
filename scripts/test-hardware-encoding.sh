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

remote=$(ssh "${ssh_options[@]}" "$host" 'mktemp -d "${TMPDIR:-/tmp}/aurelia-hardware.XXXXXX"')
cleanup() { ssh "${ssh_options[@]}" "$host" "rm -rf '$remote'" || true; }
trap cleanup EXIT

ssh "${ssh_options[@]}" "$host" 'command -v dotnet >/dev/null && command -v ffmpeg >/dev/null' \
  || { echo "$host needs the .NET SDK and ffmpeg for this test." >&2; exit 1; }
ssh "${ssh_options[@]}" "$host" 'ffmpeg -hide_banner -encoders 2>/dev/null | grep -E "h264_(nvenc|qsv|vaapi)" || true; ls /dev/dri 2>/dev/null || true'

git -C "$repository_root" archive --format=tar HEAD -- Aurelia.slnx Directory.Build.props Directory.Packages.props global.json NuGet.Config src tests \
  | ssh "${ssh_options[@]}" "$host" "tar -x -C '$remote'"
ssh "${ssh_options[@]}" "$host" "cd '$remote' && AURELIA_HARDWARE_TESTS=1 DOTNET_CLI_TELEMETRY_OPTOUT=1 dotnet test tests/Aurelia.Server.Tests --filter Category=HardwareEncoding --logger 'console;verbosity=normal'"
