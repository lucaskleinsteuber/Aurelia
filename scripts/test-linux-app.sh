#!/bin/bash
# Verifies Aurelia for Linux (clients/linux) on the Mac or on Linux: restore, formatting, a
# warning-free Release build, and the headless tests (app logic, and the real views drawn by Skia
# without a screen). Rendered frames are kept in Test Results/LinuxApp-<run-id>/snapshots so a
# person can look at them.
set -euo pipefail
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repository_root/scripts/workspace-paths.sh"
# Old builds and test results are removed first; see prune-workspace.sh.
/bin/sh "$repository_root/scripts/prune-workspace.sh" || true
export DOTNET_ROOT="${DOTNET_ROOT:-$(dirname -- "$DOTNET_BIN")}" DOTNET_NOLOGO=1 DOTNET_CLI_TELEMETRY_OPTOUT=1
solution="$repository_root/clients/linux/Aurelia.Linux.slnx"
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
results="$other_root/Test Results/LinuxApp-$run_id"
log="$other_root/Logs/LinuxApp-test-$run_id.log"
mkdir -p "$results" "$other_root/Logs"

{
  "$DOTNET_BIN" restore "$solution"
  "$DOTNET_BIN" format "$solution" --verify-no-changes --no-restore
  "$DOTNET_BIN" build "$solution" --configuration Release --no-restore
  AURELIA_LINUX_SNAPSHOTS="$results/snapshots" "$DOTNET_BIN" test "$solution" --configuration Release --no-build \
    --results-directory "$results" --logger "trx;LogFileName=tests.trx"
} 2>&1 | tee "$log"
echo "Aurelia for Linux test results: $results"
echo "Aurelia for Linux test log: $log"
