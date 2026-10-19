#!/bin/bash
# Runs the Windows x64 server build under CrossOver's Wine on this Mac with synthetic data only:
# the server starts, migrates a fresh database and answers on 127.0.0.1, and the Windows file
# code (scan identities, handle-checked playback opens, folder listing, refusal of links) passes
# tools/Aurelia.Server.WindowsProbe. Wine is not Windows: it lacks ECDSA keys and PBKDF2, so HTTPS
# and accounts cannot be exercised here. The prefix lives in the workspace, never in CrossOver's
# own bottles, and nothing listens beyond this computer.
set -euo pipefail
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repository_root/scripts/workspace-paths.sh"
export DOTNET_ROOT="${DOTNET_ROOT:-$(dirname -- "$DOTNET_BIN")}"
crossover=${AURELIA_CROSSOVER_ROOT:-/Applications/CrossOver.app/Contents/SharedSupport/CrossOver}
[ -x "$crossover/bin/wineloader" ] || { echo "CrossOver's Wine was not found at $crossover." >&2; exit 2; }
work="$other_root/Build/WineTest"
run="$work/run-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$run/data" "$run/probe/Movies/Synthetic Movie (2020)" "$run/probe/Outside"

for project in src/Aurelia.Server tools/Aurelia.Server.WindowsProbe; do
  "$DOTNET_BIN" publish "$repository_root/$project" --configuration Release --runtime win-x64 --self-contained true \
    -p:DebugType=none --output "$work/$(basename "$project")-win-x64" >/dev/null
done

export CX_ROOT="$crossover" WINEPREFIX="$work/prefix" WINEDEBUG=-all WINESERVER="$crossover/bin/wineserver"
# No browser engine, menu entries or crash debugger windows; mscoree stays, .NET needs it to load assemblies.
export WINEDLLOVERRIDES="mshtml=;winemenubuilder.exe=d;winedbg.exe=d"
to_windows() { printf 'Z:%s' "$1" | tr '/' '\\'; }
cleanup() { "$crossover/bin/wineserver" -k 2>/dev/null || true; }
trap cleanup EXIT

printf '%s' '{"version":2,"serverName":"Wine Test","lanAccessEnabled":false,"lanHttpsPort":47111,"bonjourEnabled":false,"monitoringEnabled":false,"automaticBackupsEnabled":false}' \
  > "$run/data/server-settings.json"
AURELIA_BOOTSTRAP_TOKEN=$(openssl rand -hex 32) Logging__LogLevel__Default=Warning \
  "$crossover/bin/wineloader" "$work/Aurelia.Server-win-x64/Aurelia.Server.exe" run --data-dir "$(to_windows "$run/data")" \
  --urls http://127.0.0.1:47110 --lan-port 47111 > "$run/server.log" 2>&1 &
started=$(date +%s)
until curl -s -m 2 http://127.0.0.1:47110/api/v1/server/info >/dev/null; do
  if grep -qs "Unhandled exception" "$run/server.log"; then cat "$run/server.log" >&2; exit 1; fi
  [ $(( $(date +%s) - started )) -lt 240 ] || { echo "The server did not start." >&2; exit 1; }
  sleep 1
done
echo "Server ready after $(( $(date +%s) - started )) s: $(curl -s http://127.0.0.1:47110/api/v1/server/info)"
echo "Readiness: $(curl -s http://127.0.0.1:47110/api/v1/health/ready)"
[ -s "$run/data/aurelia.db" ] || { echo "No database was created." >&2; exit 1; }
cleanup

python3 -c "import sys; open(sys.argv[1],'wb').write(bytes(i % 251 for i in range(2_000_000)))" \
  "$run/probe/Movies/Synthetic Movie (2020)/Synthetic Movie (2020).mkv"
printf 'outside' > "$run/probe/Outside/Secret (2021).mkv"
ln -s "$run/probe/Outside" "$run/probe/Movies/Linked"
"$crossover/bin/wineloader" "$work/Aurelia.Server.WindowsProbe-win-x64/Aurelia.Server.WindowsProbe.exe" "$(to_windows "$run/probe")"
rm -rf "$run"
