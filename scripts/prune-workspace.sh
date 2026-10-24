#!/bin/sh
# Removes old generated output so the external workspace does not grow without bound.
# Build and test scripts call this before they write anything new. It keeps:
#   - the newest numbered Mac builds ("Build <n>") and the newest tvOS and Linux builds
#     (AURELIA_KEEP_BUILDS, default 2 each); published releases are on GitHub;
#   - the newest test result bundles (AURELIA_KEEP_TEST_RESULTS, default 10);
#   - logs from the last 30 days;
#   - one-off output in Build/ and test run folders from the last day, so a run in progress is
#     never touched.
# It never touches the Package Cache, the build summaries or anything outside these folders.
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repository_root/scripts/workspace-paths.sh"
keep_builds=${AURELIA_KEEP_BUILDS:-2}
keep_results=${AURELIA_KEEP_TEST_RESULTS:-10}

case "$other_root" in
  "" | / | "$HOME" | "$HOME/")
    echo "Refusing to prune the workspace at '$other_root'." >&2
    exit 1
    ;;
esac
[ -d "$other_root" ] || exit 0

# Removes every line of stdin after the first $1, each a name inside directory $2.
remove_all_but() {
  tail -n +"$(($1 + 1))" | while IFS= read -r name; do
    [ -n "$name" ] && rm -rf -- "$2/$name"
  done
}

build="$other_root/Build"
if [ -d "$build" ]; then
  ls "$build" | grep -E '^Build [0-9]+$' | sort -k2 -n -r | remove_all_but "$keep_builds" "$build"
  for platform in tvOS Linux; do
    if [ -d "$build/$platform" ]; then
      ls -t "$build/$platform" | remove_all_but "$keep_builds" "$build/$platform"
    fi
  done
  find "$build" -mindepth 1 -maxdepth 1 ! -name 'Build [0-9]*' ! -name tvOS ! -name Linux \
    -mtime +1 -exec rm -rf -- {} +
fi

results="$other_root/Test Results"
if [ -d "$results" ]; then
  ls -t "$results" | remove_all_but "$keep_results" "$results"
fi
if [ -d "$other_root/Logs" ]; then
  find "$other_root/Logs" -type f -mtime +30 -delete
fi

if [ "$(uname -s)" = Darwin ]; then
  for runs in "$HOME/Library/Caches/Aurelia/TestRuns" /private/tmp/Aurelia; do
    if [ -d "$runs" ]; then
      find "$runs" -mindepth 1 -maxdepth 1 -mtime +0 -exec rm -rf -- {} +
    fi
  done
fi
exit 0
