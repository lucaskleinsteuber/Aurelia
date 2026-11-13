#!/bin/zsh
# Server benchmarks ("Messen statt raten"): a synthetic library of 20,000 episodes and 5,000
# movies, over real HTTP, with limits for time and database queries in
# tests/Aurelia.Server.Tests/Benchmarks/limits.json. Run before every server version; a path that
# got slower or runs more queries fails. The limits were measured on a Mac, so run it there.
set -euo pipefail

repository_root=${0:A:h:h}
source "$repository_root/scripts/workspace-paths.sh"
/bin/sh "$repository_root/scripts/prune-workspace.sh" || true
run_id="server-benchmarks-$(date -u +%Y%m%dT%H%M%SZ)"
results="$other_root/Test Results/$run_id"
log="$other_root/Logs/$run_id.log"
mkdir -p "$results" "$other_root/Logs"

# One benchmark after another, so they never share the processor with each other.
AURELIA_BENCHMARKS=1 "$DOTNET_BIN" test "$repository_root/tests/Aurelia.Server.Tests/Aurelia.Server.Tests.csproj" \
  --configuration Release --filter "Category=Benchmark" \
  --results-directory "$results" --logger "trx;LogFileName=benchmarks.trx" \
  --logger "console;verbosity=detailed" \
  -- xUnit.ParallelizeTestCollections=false 2>&1 | tee "$log"
exit_code=${pipestatus[1]}
grep -E "SERVER_BENCHMARK|CATALOG_BENCHMARK " "$log" | sed 's/^ *//' > "$results/benchmarks.jsonl" || true
print "Server benchmark results: $results"
print "Server benchmark log: $log"
exit "$exit_code"
