#!/bin/sh
# Internal helper dispatched by capture-showcase.sh --web-only, using the same invented library.
# Headless developer capture only: no owner browser, real server, credentials, video or UI suite.
set -eu
if [ "${1:-}" = "--help" ]; then
  echo "Usage: zsh scripts/capture-showcase.sh --web-only"
  echo "Uses an existing Playwright/Chromium installation; set AURELIA_PLAYWRIGHT_NODE_MODULES or NODE_PATH."
  exit 0
fi
if [ "$#" -ne 0 ]; then echo "Use --help for usage." >&2; exit 2; fi
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repository_root/scripts/workspace-paths.sh"
if [ -n "${AURELIA_PLAYWRIGHT_NODE_MODULES:-}" ]; then
  NODE_PATH=$AURELIA_PLAYWRIGHT_NODE_MODULES${NODE_PATH:+:$NODE_PATH}
  export NODE_PATH
fi
node_bin=${AURELIA_NODE:-node}
"$node_bin" "$repository_root/scripts/capture-web-showcase.mjs" --check
sh "$repository_root/scripts/prune-workspace.sh" --workspace-only
cache_base=${XDG_CACHE_HOME:-$HOME/.cache}
if [ "$(uname -s)" = Darwin ]; then cache_base="$HOME/Library/Caches"; fi
mkdir -p "$cache_base/Aurelia/TestRuns"
run_root=$(mktemp -d "$cache_base/Aurelia/TestRuns/web-showcase.XXXXXX")
child_pid=
cleanup() {
  if [ -n "$child_pid" ]; then
    kill -TERM "$child_pid" 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
  fi
  rm -rf "$run_root"
}
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
swift "$repository_root/scripts/make-showcase.swift" "$run_root/Showcase" &
child_pid=$!
wait "$child_pid"
child_pid=
version=$(sed -n 's/.*<Version>\([^<]*\)<\/Version>.*/\1/p' "$repository_root/Directory.Build.props" | head -n 1)
report="$other_root/Logs/Browser Showcase $(date +%Y%m%d-%H%M%S).json"
"$node_bin" "$repository_root/scripts/capture-web-showcase.mjs" \
  --web-root "$repository_root/src/Aurelia.Server/WebApp" \
  --showcase-root "$run_root/Showcase" \
  --output "$repository_root/docs/assets/screenshots" --version "$version" --report "$report" &
child_pid=$!
wait "$child_pid"
child_pid=
