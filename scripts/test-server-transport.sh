#!/bin/sh
set -eu
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repository_root/scripts/workspace-paths.sh"
duration=${1:-7200}
clients=${2:-4}
mkdir -p "$other_root/Test Results"
report="$other_root/Test Results/Aurelia-Transport-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
"$DOTNET_BIN" build "$repository_root/src/Aurelia.Server/Aurelia.Server.csproj" --configuration Release
"$DOTNET_BIN" run --project "$repository_root/tools/Aurelia.Server.TransportProbe" --configuration Release -- \
  "$other_root/Build/bin/Aurelia.Server/Release/net10.0/Aurelia.Server" "$report" "$duration" "$clients"
