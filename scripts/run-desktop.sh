#!/bin/sh
# Starts the desktop (Windows/Linux) client natively on this Mac for everyday testing.
# The same views and styles run on Windows; real Windows checks use a Windows VM.
set -eu
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repository_root/scripts/workspace-paths.sh"
export DOTNET_ROOT="${DOTNET_ROOT:-$(dirname -- "$DOTNET_BIN")}"
exec "$DOTNET_BIN" run --project "$repository_root/clients/desktop/Aurelia.Desktop/Aurelia.Desktop.csproj" "$@"
