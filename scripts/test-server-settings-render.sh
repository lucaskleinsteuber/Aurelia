#!/bin/zsh
set -euo pipefail

repository_root=${0:A:h:h}
other_root=${AURELIA_OTHER_ROOT:-"${repository_root:h}/Aurelia Other"}
source_candidate=${1:?Provide a signed Debug Aurelia.app built with warnings as errors.}
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$(uuidgen | tr '[:upper:]' '[:lower:]')"
runtime_root="/private/tmp/Aurelia/$run_id"
candidate="$runtime_root/Aurelia.app"
output="$runtime_root/ServerSettings.png"
report="$other_root/Test Results/Server-Settings-Render-$run_id.png"
application_pid=''
cleanup_finished=false

cleanup() {
  local exit_code=${1:-$?}
  [[ "$cleanup_finished" == true ]] && return "$exit_code"
  cleanup_finished=true
  set +e
  [[ -n "$application_pid" ]] && kill "$application_pid" 2>/dev/null || true
  find "$runtime_root" -depth -delete 2>/dev/null || true
  return "$exit_code"
}
trap 'cleanup $?' EXIT
TRAPZERR() {
  local failure_code=$?
  cleanup "$failure_code"
  exit "$failure_code"
}

mkdir -m 700 -p "$runtime_root"
mkdir -p "$other_root/Test Results"
/usr/bin/ditto "$source_candidate" "$candidate"
/usr/bin/open -n -g --env AURELIA_UI_TEST_MODE=server-settings \
  --env "AURELIA_SERVER_SETTINGS_RENDER=$output" \
  --env AURELIA_SERVER_SETTINGS_RENDER_STDOUT=1 --stdout "$output" \
  --stderr "$runtime_root/render-error.txt" "$candidate" \
  --args -ApplePersistenceIgnoreState YES
for _ in {1..100}; do
  [[ -s "$output" ]] && break
  application_pid="$(pgrep -f "^$candidate/Contents/MacOS/Aurelia( |$)" | tail -1 || true)"
  sleep 0.2
done
[[ -s "$output" && "$(stat -f '%z' "$output")" -gt 10000 ]] \
  || {
    [[ -f "$runtime_root/render-error.txt" ]] && sed -n '1,8p' "$runtime_root/render-error.txt" >&2
    print 'Native server settings rendering did not complete.' >&2
    exit 1
  }
/usr/bin/ditto "$output" "$report"
print -r -- "Native server settings rendered using synthetic read-only API fixtures: $report"
