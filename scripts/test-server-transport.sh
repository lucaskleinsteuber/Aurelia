#!/bin/sh
set -eu
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repository_root/scripts/workspace-paths.sh"
duration=${1:-7200}
clients=${2:-4}
server_build_root=${TARVEN_BUILD_ROOT:-"$other_root/Build"}
mkdir -p "$other_root/Test Results"
report="$other_root/Test Results/Tarven-Transport-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
"$DOTNET_BIN" build "$repository_root/src/Tarven.Server/Tarven.Server.csproj" --configuration Release
"$DOTNET_BIN" run --project "$repository_root/tools/Tarven.Server.TransportProbe" --configuration Release -- \
  "$server_build_root/bin/Tarven.Server/Release/net10.0/Tarven.Server" "$report" "$duration" "$clients"
