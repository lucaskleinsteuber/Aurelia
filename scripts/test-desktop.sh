#!/bin/sh
# Format check, warning-free build, headless UI tests and end-to-end tests against a real
# synthetic server for the desktop client. No window opens and nothing leaves this computer.
set -eu
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repository_root/scripts/workspace-paths.sh"
export DOTNET_ROOT="${DOTNET_ROOT:-$(dirname -- "$DOTNET_BIN")}"
solution="$repository_root/clients/desktop/Aurelia.Desktop.slnx"
# The end-to-end tests start this server build with synthetic data on loopback only.
"$DOTNET_BIN" build "$repository_root/src/Aurelia.Server/Aurelia.Server.csproj" --configuration Release
server_build_root=${AURELIA_BUILD_ROOT:-"$other_root/Build"}
export AURELIA_TEST_SERVER="$server_build_root/bin/Aurelia.Server/Release/net10.0/Aurelia.Server"
"$DOTNET_BIN" restore "$solution"
"$DOTNET_BIN" format "$solution" --verify-no-changes --no-restore
"$DOTNET_BIN" build "$solution" --configuration Release --no-restore
"$DOTNET_BIN" test "$solution" --configuration Release --no-build
