#!/bin/sh
# Format check, warning-free build and headless UI tests for the desktop client.
# Headless tests render the real views with Skia; no window opens on screen.
set -eu
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repository_root/scripts/workspace-paths.sh"
export DOTNET_ROOT="${DOTNET_ROOT:-$(dirname -- "$DOTNET_BIN")}"
solution="$repository_root/clients/desktop/Aurelia.Desktop.slnx"
"$DOTNET_BIN" restore "$solution"
"$DOTNET_BIN" format "$solution" --verify-no-changes --no-restore
"$DOTNET_BIN" build "$solution" --configuration Release --no-restore
"$DOTNET_BIN" test "$solution" --configuration Release --no-build
