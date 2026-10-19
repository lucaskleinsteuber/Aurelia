#!/bin/sh
# Starts the desktop (Windows/Linux) client natively on this Mac for everyday testing.
# The same views and styles run on Windows; real Windows checks use a Windows VM.
set -eu
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repository_root/scripts/workspace-paths.sh"
export DOTNET_ROOT="${DOTNET_ROOT:-$(dirname -- "$DOTNET_BIN")}"
# "Set Up This Computer" hosts this server build. On a Mac it keeps its own data folder
# (Aurelia Desktop/Server), its own ports (43120, 43121) and no network access unless turned
# on, so the installed Aurelia app and its server are never touched.
"$DOTNET_BIN" build "$repository_root/src/Aurelia.Server/Aurelia.Server.csproj" --configuration Release >/dev/null
export AURELIA_DESKTOP_SERVER="${AURELIA_BUILD_ROOT:-"$other_root/Build"}/bin/Aurelia.Server/Release/net10.0/Aurelia.Server"
exec "$DOTNET_BIN" run --project "$repository_root/clients/desktop/Aurelia.Desktop/Aurelia.Desktop.csproj" "$@"
