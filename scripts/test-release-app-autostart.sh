#!/bin/zsh
set -euo pipefail

repository_root=${0:A:h:h}
source "$repository_root/scripts/workspace-paths.sh"
build_number=$(sed -n 's/^CURRENT_PROJECT_VERSION = \([0-9][0-9]*\)$/\1/p' "$repository_root/clients/macos/Configuration/BuildNumber.xcconfig")
source_candidate=${1:-"$other_root/Build/Build $build_number/Aurelia.app"}
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$(uuidgen | tr '[:upper:]' '[:lower:]')"
runtime_root="/private/tmp/Aurelia/$run_id"
candidate="$runtime_root/Aurelia.app"
data_root="$runtime_root/Data"
host_log_root="$runtime_root/Logs"
result_root="$other_root/Test Results"
log_root="$other_root/Logs"
report="$result_root/Aurelia-ReleaseAppAutostart-$run_id.txt"
application="$candidate/Contents/MacOS/Aurelia"
helper="$candidate/Contents/Helpers/Aurelia Server Host.app/Contents/MacOS/AureliaServerHost"
application_pid=''
helper_pid=''
cleanup_finished=false

cleanup() {
  local exit_code=${1:-$?}
  [[ "$cleanup_finished" == true ]] && return "$exit_code"
  cleanup_finished=true
  set +e
  if [[ -n "$application_pid" ]] && kill -0 "$application_pid" 2>/dev/null; then
    kill "$application_pid" 2>/dev/null || true
  fi
  if [[ -n "$helper_pid" ]] && kill -0 "$helper_pid" 2>/dev/null; then
    kill "$helper_pid" 2>/dev/null || true
  fi
  if [[ "$exit_code" -ne 0 && -f "$host_log_root/server.log" ]]; then
    cp "$host_log_root/server.log" "$log_root/Aurelia-ReleaseAppAutostart-$run_id.log"
  fi
  if [[ "$runtime_root" == /private/tmp/Aurelia/* ]]; then
    find "$runtime_root" -depth -delete 2>/dev/null || true
  fi
  return "$exit_code"
}
trap 'cleanup $?' EXIT
TRAPZERR() {
  local failure_code=$?
  cleanup "$failure_code"
  exit "$failure_code"
}

fail() {
  print -r -- "FAIL: $1" | tee -a "$report" >&2
  exit 1
}

mkdir -p "$runtime_root" "$data_root" "$host_log_root" "$result_root" "$log_root"
chmod 700 "$runtime_root" "$data_root" "$host_log_root"
[[ -d "$source_candidate" ]] || fail "The Build $build_number app candidate does not exist."
/usr/bin/ditto "$source_candidate" "$candidate"
[[ -x "$application" && -x "$helper" ]] || fail "The staged release app is incomplete."

if pgrep -x Aurelia >/dev/null 2>&1 || pgrep -x AureliaServerHost >/dev/null 2>&1; then
  fail "Aurelia is already running; no existing process was stopped."
fi
if lsof -nP -iTCP:43110 -sTCP:LISTEN >/dev/null 2>&1; then
  fail "Loopback port 43110 is already occupied; no existing process was stopped."
fi

print -r -- "Aurelia Build $build_number release app autostart smoke test" >"$report"
print -r -- "Run: $run_id" >>"$report"

/usr/bin/open -n -g \
  --env AURELIA_PREFLIGHT_TEST=1 \
  --env "AURELIA_DATA_DIR=$data_root" \
  --env "AURELIA_LOG_DIR=$host_log_root" \
  "$candidate" --args \
  -ApplePersistenceIgnoreState YES \
  -AureliaOperatingMode host \
  -AureliaOperatingModeSelectionVersion 1

for _ in {1..100}; do
  application_pid="$(pgrep -f "^$application( |$)" | tail -1 || true)"
  [[ -n "$application_pid" ]] && kill -0 "$application_pid" 2>/dev/null && break
  sleep 0.1
done
[[ -n "$application_pid" ]] && kill -0 "$application_pid" 2>/dev/null \
  || fail "Launch Services did not start the staged app."

for _ in {1..150}; do
  helper_pid="$(pgrep -f "^$helper( |$)" | tail -1 || true)"
  [[ -n "$helper_pid" ]] && kill -0 "$helper_pid" 2>/dev/null && break
  sleep 0.1
done
[[ -n "$helper_pid" ]] && kill -0 "$helper_pid" 2>/dev/null \
  || fail "The app did not launch its bundled server helper through the App Group."

for _ in {1..150}; do
  curl --silent --max-time 1 'http://127.0.0.1:43110/api/v1/server/info' \
    >"$runtime_root/server-info.json" 2>/dev/null && break
  kill -0 "$helper_pid" 2>/dev/null || fail "The helper exited before the server became ready."
  sleep 0.2
done
[[ "$(jq -r 'if has("isSetup") then .isSetup else empty end' "$runtime_root/server-info.json" 2>/dev/null)" == false ]] \
  || fail "The fresh loopback server did not become ready for owner setup."

DEVELOPER_DIR="$developer_dir" /usr/bin/swift -e \
  'import AppKit; guard let pid = Int32(CommandLine.arguments[1]), let app = NSRunningApplication(processIdentifier: pid), app.terminate() else { exit(1) }' \
  "$application_pid"
for _ in {1..150}; do
  if ! kill -0 "$application_pid" 2>/dev/null && ! kill -0 "$helper_pid" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
kill -0 "$application_pid" 2>/dev/null && fail "The app did not quit cleanly."
kill -0 "$helper_pid" 2>/dev/null && fail "The helper survived the app's clean shutdown."
application_pid=''
helper_pid=''

{
  print -r -- "PASS: Launch Services started the signed staged app"
  print -r -- "PASS: the app launched its helper through the shared App Group"
  print -r -- "PASS: loopback port 43110 served /api/v1/server/info"
  print -r -- "PASS: quitting the app stopped both helper and server"
  print -r -- "PASS: no manual handoff file or bootstrap-directory override was used"
} >>"$report"

print -r -- "Release app autostart smoke test passed. Report: $report"
