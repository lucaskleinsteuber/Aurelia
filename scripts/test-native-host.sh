#!/bin/zsh
set -euo pipefail

repository_root=${0:A:h:h}
other_root=${AURELIA_OTHER_ROOT:-"${repository_root:h}/Aurelia Other"}
build_number=$(sed -n 's:.*<AureliaBuildNumber>\([0-9][0-9]*\)</AureliaBuildNumber>.*:\1:p' "$repository_root/Directory.Build.props")
source_candidate=${1:-"$other_root/Build/Build $build_number/Aurelia.app"}
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$(uuidgen | tr '[:upper:]' '[:lower:]')"
runtime_root="/private/tmp/Aurelia/$run_id"
candidate="$runtime_root/Aurelia.app"
result_root="$other_root/Test Results"
log_root="$other_root/Logs"
report="$result_root/Aurelia-NativeHost-$run_id.txt"
copied_log="$log_root/Aurelia-NativeHost-$run_id.log"
helper="$candidate/Contents/Helpers/Aurelia Server Host.app/Contents/MacOS/AureliaServerHost"
application="$candidate/Contents/MacOS/Aurelia"
server="$candidate/Contents/Resources/Server/osx-arm64/Aurelia.Server"
data_root="$runtime_root/Data"
host_log_root="$runtime_root/Logs"
secret="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')"
owner_password='native-host-smoke-password-123!'
helper_pid=''
application_pid=''
bootstrap_root="$runtime_root/Host"
rendezvous="$bootstrap_root/rendezvous-$run_id.json"
configuration=''
secret_pipe=''

cleanup() {
  exit_code=$?
  set +e
  if [[ "$exit_code" -ne 0 ]]; then
    if [[ -f "$runtime_root/helper-output.log" ]]; then
      cp "$runtime_root/helper-output.log" "$log_root/Aurelia-NativeHost-$run_id-helper.log"
    fi
    if [[ -f "$host_log_root/server.log" ]]; then
      cp "$host_log_root/server.log" "$copied_log"
    fi
  fi
  if [[ -n "$helper_pid" ]] && kill -0 "$helper_pid" 2>/dev/null; then
    if [[ -n "${control_base:-}" ]]; then
      curl --silent --max-time 2 --request POST "$control_base/shutdown" >/dev/null 2>&1
    fi
    for _ in {1..40}; do
      kill -0 "$helper_pid" 2>/dev/null || break
      sleep 0.1
    done
    kill "$helper_pid" 2>/dev/null || true
  fi
  if [[ -n "$application_pid" ]] && kill -0 "$application_pid" 2>/dev/null; then
    kill "$application_pid" 2>/dev/null || true
  fi
  [[ -n "$configuration" ]] && rm -f "$configuration"
  [[ -n "$secret_pipe" ]] && rm -f "$secret_pipe"
  [[ -n "$rendezvous" ]] && rm -f "$rendezvous"
  if [[ "$runtime_root" == /private/tmp/Aurelia/* ]]; then
    find "$runtime_root" -depth -delete 2>/dev/null || true
  fi
  return "$exit_code"
}
trap cleanup EXIT

fail() {
  if [[ -f "$runtime_root/helper-output.log" ]]; then
    cp "$runtime_root/helper-output.log" "$log_root/Aurelia-NativeHost-$run_id-helper.log"
  fi
  if [[ -f "$host_log_root/server.log" ]]; then
    cp "$host_log_root/server.log" "$copied_log"
  fi
  print -r -- "FAIL: $1" | tee -a "$report" >&2
  exit 1
}

wait_for_file() {
  local file_path=$1
  for _ in {1..100}; do
    [[ -s "$file_path" ]] && return 0
    kill -0 "$helper_pid" 2>/dev/null || return 1
    sleep 0.1
  done
  return 1
}

wait_for_state() {
  local expected=$1
  local status_file="$runtime_root/status.json"
  for _ in {1..150}; do
    if curl --silent --max-time 1 "$control_base/status" >"$status_file" 2>/dev/null; then
      [[ "$(jq -r '.state // empty' "$status_file")" == "$expected" ]] && return 0
      [[ "$(jq -r '.state // empty' "$status_file")" == failed ]] && return 1
    fi
    sleep 0.2
  done
  return 1
}

mkdir -p "$runtime_root" "$data_root" "$host_log_root" "$result_root" "$log_root"
mkdir -m 700 "$bootstrap_root"
[[ -d "$source_candidate" ]] || fail "The Build $build_number app candidate does not exist."
/usr/bin/ditto "$source_candidate" "$candidate"
[[ -x "$application" ]] || fail "The native Aurelia app is missing."
[[ -x "$helper" ]] || fail "The native server host helper is missing."
[[ -x "$server" ]] || fail "The embedded arm64 server is missing."
if lsof -nP -iTCP:43110 -sTCP:LISTEN >/dev/null 2>&1; then
  fail "Loopback port 43110 is already occupied; no existing process was stopped."
fi

print -r -- "Aurelia Build $build_number native host smoke test" >"$report"
print -r -- "Run: $run_id" >>"$report"

lan_port="$(ruby -rsocket -e 'server = TCPServer.new("127.0.0.1", 0); puts server.addr[1]; server.close')"
open -na "$candidate" --args -AureliaOperatingMode client
for _ in {1..50}; do
  application_pid="$(pgrep -f "^$application( |$)" | tail -1 || true)"
  [[ -n "$application_pid" ]] && kill -0 "$application_pid" 2>/dev/null && break
  sleep 0.1
done
[[ -n "$application_pid" ]] && kill -0 "$application_pid" 2>/dev/null \
  || fail "The parent Aurelia app did not start through Launch Services."

mkdir -p "$bootstrap_root"
configuration="$bootstrap_root/launch-$application_pid.json"
secret_pipe="$bootstrap_root/launch-$application_pid.pipe"
rm -f "$configuration" "$secret_pipe"
mkfifo -m 600 "$secret_pipe"
jq -cn \
  --argjson parentProcessID "$application_pid" \
  --arg rendezvousPath "$rendezvous" \
  --arg secretPipePath "$secret_pipe" \
  --arg dataDirectory "$data_root" \
  --arg logDirectory "$host_log_root" \
  --arg serverName 'Aurelia Host Smoke' \
  --argjson lanPort "$lan_port" \
  '{version:1,parentProcessID:$parentProcessID,rendezvousPath:$rendezvousPath,secretPipePath:$secretPipePath,dataDirectory:$dataDirectory,logDirectory:$logDirectory,serverName:$serverName,lanPort:$lanPort}' \
  >"$configuration"
chmod 600 "$configuration"
exec 9<>"$secret_pipe"
print -rn -- "$secret" >&9
AURELIA_HOST_BOOTSTRAP_DIR="$bootstrap_root" \
  "$helper" >"$runtime_root/helper-output.log" 2>&1 &
helper_pid=$!
[[ -n "$helper_pid" ]] && kill -0 "$helper_pid" 2>/dev/null \
  || fail "The server host helper did not start."

wait_for_file "$rendezvous" || fail "The helper did not create its rendezvous file."
exec 9>&-
[[ ! -e "$configuration" && ! -e "$secret_pipe" ]] \
  || fail "The helper did not remove the consumed launch handoff."
control_port="$(jq -r '.port // empty' "$rendezvous")"
[[ "$control_port" == <1-65535> ]] || fail "The helper returned an invalid control port."
control_base="http://127.0.0.1:$control_port/$secret"
wait_for_state setupRequired || fail "The loopback bootstrap server did not become ready."

wrong_status="$(curl --silent --output /dev/null --write-out '%{http_code}' \
  "http://127.0.0.1:$control_port/invalid-secret/status")"
[[ "$wrong_status" == 404 ]] || fail "The helper accepted an invalid control secret."

bootstrap="$(jq -r '.bootstrapToken // empty' "$runtime_root/status.json")"
[[ ${#bootstrap} -ge 43 ]] || fail "The helper did not provide a one-time bootstrap token."
setup_body="$(jq -cn \
  --arg username 'host-smoke-owner' \
  --arg password "$owner_password" \
  --arg deviceName 'Native Host Smoke' \
  '{username:$username,password:$password,deviceName:$deviceName}')"
curl --silent --show-error --fail-with-body \
  --header 'Content-Type: application/json' \
  --header "X-Aurelia-Bootstrap-Token: $bootstrap" \
  --data "$setup_body" \
  'http://127.0.0.1:43110/api/v1/setup/owner' >"$runtime_root/authentication.json"

token="$(jq -r '.token // empty' "$runtime_root/authentication.json")"
[[ ${#token} -ge 43 ]] || fail "Owner setup did not return a device token."
configure_body="$(jq -cn \
  --arg serverName 'Aurelia Host Smoke' \
  --argjson lanHttpsPort "$lan_port" \
  '{version:1,serverName:$serverName,lanAccessEnabled:true,lanHttpsPort:$lanHttpsPort}')"
curl --silent --show-error --fail-with-body \
  --request POST --header 'Content-Type: application/json' --data "$configure_body" \
  "$control_base/configure" >/dev/null
curl --silent --show-error --fail-with-body --request POST \
  "$control_base/restart" >/dev/null
wait_for_state running || fail "The helper did not restart the server with LAN HTTPS enabled."

https_base="https://127.0.0.1:$lan_port"
for _ in {1..100}; do
  curl --silent --insecure --max-time 1 "$https_base/api/v1/server/info" \
    >"$runtime_root/server-info.json" 2>/dev/null && break
  sleep 0.2
done
[[ "$(jq -r '.lanAccessEnabled // false' "$runtime_root/server-info.json" 2>/dev/null)" == true ]] \
  || fail "LAN HTTPS server information was unavailable."

reported_fingerprint="$(jq -r '.publicKeyFingerprint // empty' "$runtime_root/server-info.json")"
observed_fingerprint="$( { openssl s_client -connect "127.0.0.1:$lan_port" -servername 127.0.0.1 </dev/null 2>/dev/null || true; } \
  | openssl x509 -pubkey -noout 2>/dev/null \
  | openssl pkey -pubin -outform DER 2>/dev/null \
  | shasum -a 256 | awk '{print toupper($1)}')"
[[ -n "$reported_fingerprint" && "$reported_fingerprint" == "$observed_fingerprint" ]] \
  || fail "The advertised TLS public-key fingerprint did not match the live certificate."

curl --silent --show-error --fail-with-body --insecure \
  --header "Authorization: Bearer $token" \
  "$https_base/api/v1/auth/me" >"$runtime_root/me.json"
[[ "$(jq -r '.role // empty' "$runtime_root/me.json")" == owner ]] \
  || fail "The authenticated owner identity was not returned by /auth/me."

fixture="$runtime_root/Fixture Movies"
mkdir -p "$fixture"
dd if=/dev/zero of="$fixture/Host Smoke Movie 2026.mkv" bs=1024 count=1 status=none
library_body="$(jq -cn --arg path "$fixture" \
  '{path:$path,kind:"automatic"}')"
curl --silent --show-error --fail-with-body --insecure \
  --header "Authorization: Bearer $token" --header 'Content-Type: application/json' \
  --data "$library_body" "$https_base/api/v1/libraries" >"$runtime_root/library.json"
library_id="$(jq -r '.id // empty' "$runtime_root/library.json")"
[[ -n "$library_id" ]] || fail "The test library was not created."
curl --silent --show-error --fail-with-body --insecure --request POST \
  --header "Authorization: Bearer $token" \
  "$https_base/api/v1/libraries/$library_id/scans" >"$runtime_root/scan.json"
scan_id="$(jq -r '.id // empty' "$runtime_root/scan.json")"
for _ in {1..100}; do
  curl --silent --show-error --fail-with-body --insecure \
    --header "Authorization: Bearer $token" \
    "$https_base/api/v1/scans/$scan_id" >"$runtime_root/scan.json"
  scan_state="$(jq -r '.state // empty' "$runtime_root/scan.json")"
  [[ "$scan_state" == completed ]] && break
  [[ "$scan_state" == failed || "$scan_state" == interrupted ]] \
    && fail "The bounded test scan did not complete."
  sleep 0.2
done
[[ "$(jq -r '.state // empty' "$runtime_root/scan.json")" == completed ]] \
  || fail "The bounded test scan timed out."

curl --silent --show-error --fail-with-body --insecure \
  --header "Authorization: Bearer $token" \
  "$https_base/api/v1/catalog/items?kind=movie&offset=0&limit=10" \
  >"$runtime_root/catalog.json"
media_id="$(jq -r '.items[0].id // empty' "$runtime_root/catalog.json")"
[[ -n "$media_id" ]] || fail "The bounded test movie did not appear in the presentation catalog."
curl --silent --show-error --fail-with-body --insecure --request POST \
  --header "Authorization: Bearer $token" \
  "$https_base/api/v1/media/$media_id/playback" >"$runtime_root/playback.json"
stream_path="$(jq -r '.streamPath // empty' "$runtime_root/playback.json")"
[[ "$stream_path" == /api/v1/streams/* ]] || fail "Direct Play did not return a relative ticket URL."
range_status="$(curl --silent --insecure --output "$runtime_root/range.bin" \
  --write-out '%{http_code}' --header 'Range: bytes=0-63' "$https_base$stream_path")"
[[ "$range_status" == 206 ]] || fail "Direct Play did not honor the bounded byte range."
[[ "$(stat -f '%z' "$runtime_root/range.bin")" == 64 ]] \
  || fail "Direct Play returned an unexpected byte count."

curl --silent --show-error --fail-with-body --insecure --request POST \
  --header "Authorization: Bearer $token" \
  "$https_base/api/v1/auth/pairings" >"$runtime_root/pairing.json"
[[ "$(jq -r '.code // empty | length' "$runtime_root/pairing.json")" == 8 ]] \
  || fail "The server did not create an eight-digit pairing code."
curl --silent --show-error --fail-with-body --insecure \
  --header "Authorization: Bearer $token" \
  "$https_base/api/v1/auth/sessions" >"$runtime_root/sessions.json"
[[ "$(jq 'length' "$runtime_root/sessions.json")" -ge 1 ]] \
  || fail "The owner session was not listed."

curl --silent --show-error --fail-with-body --request POST \
  "$control_base/shutdown" >/dev/null
for _ in {1..120}; do
  kill -0 "$helper_pid" 2>/dev/null || break
  sleep 0.1
done
kill -0 "$helper_pid" 2>/dev/null && fail "The helper did not stop after a graceful shutdown request."
wait "$helper_pid" 2>/dev/null || true
helper_pid=''

quick_check="$(sqlite3 "$data_root/aurelia.db" 'PRAGMA quick_check;')"
integrity_check="$(sqlite3 "$data_root/aurelia.db" 'PRAGMA integrity_check;')"
foreign_keys="$(sqlite3 "$data_root/aurelia.db" 'PRAGMA foreign_key_check;')"
[[ "$quick_check" == ok && "$integrity_check" == ok && -z "$foreign_keys" ]] \
  || fail "SQLite integrity verification failed."

for log_path in "$host_log_root/server.log" "$host_log_root/server.previous.log"; do
  [[ -f "$log_path" ]] || continue
  size="$(stat -f '%z' "$log_path")"
  [[ "$size" -le 1048576 ]] || fail "A production log exceeded the 1 MiB limit."
  contents="$(<"$log_path")"
  [[ "$contents" != *"$secret"* && "$contents" != *"$bootstrap"* \
    && "$contents" != *"$token"* && "$contents" != *"$owner_password"* ]] \
    || fail "A secret appeared in a server log."
done

secret="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')"
rendezvous="$bootstrap_root/parent-abort-rendezvous-$run_id.json"
configuration="$bootstrap_root/launch-$application_pid.json"
secret_pipe="$bootstrap_root/launch-$application_pid.pipe"
rm -f "$configuration" "$secret_pipe"
mkfifo -m 600 "$secret_pipe"
jq -cn \
  --argjson parentProcessID "$application_pid" \
  --arg rendezvousPath "$rendezvous" \
  --arg secretPipePath "$secret_pipe" \
  --arg dataDirectory "$data_root" \
  --arg logDirectory "$host_log_root" \
  --arg serverName 'Aurelia Host Smoke' \
  --argjson lanPort "$lan_port" \
  '{version:1,parentProcessID:$parentProcessID,rendezvousPath:$rendezvousPath,secretPipePath:$secretPipePath,dataDirectory:$dataDirectory,logDirectory:$logDirectory,serverName:$serverName,lanPort:$lanPort}' \
  >"$configuration"
chmod 600 "$configuration"
exec 9<>"$secret_pipe"
print -rn -- "$secret" >&9
AURELIA_HOST_BOOTSTRAP_DIR="$bootstrap_root" \
  "$helper" >"$runtime_root/helper-output.log" 2>&1 &
helper_pid=$!
[[ -n "$helper_pid" ]] && kill -0 "$helper_pid" 2>/dev/null \
  || fail "The parent-abort server host helper did not start."
wait_for_file "$rendezvous" || fail "The parent-abort helper did not start."
exec 9>&-
kill "$application_pid"
wait "$application_pid" 2>/dev/null || true
application_pid=''
for _ in {1..120}; do
  kill -0 "$helper_pid" 2>/dev/null || break
  sleep 0.1
done
kill -0 "$helper_pid" 2>/dev/null \
  && fail "The helper did not stop when its parent app disappeared."
wait "$helper_pid" 2>/dev/null || true
helper_pid=''

if [[ -f "$host_log_root/server.log" ]]; then
  cp "$host_log_root/server.log" "$copied_log"
fi
{
  print -r -- "PASS: helper control channel rejected an invalid secret"
  print -r -- "PASS: one-time owner bootstrap and LAN HTTPS restart"
  print -r -- "PASS: live TLS public-key fingerprint matched server identity"
  print -r -- "PASS: /auth/me, library creation, bounded scan, pairing, and sessions"
  print -r -- "PASS: authenticated Direct Play returned the requested 64-byte original-file range"
  print -r -- "PASS: graceful helper/server shutdown"
  print -r -- "PASS: helper stopped when its PID-bound parent app disappeared"
  print -r -- "PASS: SQLite quick_check and integrity_check; foreign keys clean"
  print -r -- "PASS: bounded logs contain no tested secrets"
} >>"$report"

print -r -- "Native host smoke test passed. Report: $report"
