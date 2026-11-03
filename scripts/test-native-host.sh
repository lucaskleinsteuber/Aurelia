#!/bin/zsh
set -euo pipefail

repository_root=${0:A:h:h}
source "$repository_root/scripts/workspace-paths.sh"
build_number=$(sed -n 's/^CURRENT_PROJECT_VERSION = \([0-9][0-9]*\)$/\1/p' "$repository_root/clients/macos/Configuration/BuildNumber.xcconfig")
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
server="$candidate/Contents/Resources/Server/osx-$([[ $(uname -m) == arm64 ]] && print arm64 || print x64)/Aurelia.Server"
data_root="$runtime_root/Data"
host_log_root="$runtime_root/Logs"
secret="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')"
owner_password='native-host-smoke-password-123!'
helper_pid=''
application_pid=''
conflict_pid=''
bootstrap_root="$runtime_root/Host"
rendezvous="$bootstrap_root/rendezvous-$run_id.json"
configuration=''
secret_pipe=''
last_phase='bootstrap'
cleanup_finished=false

cleanup() {
  local exit_code=${1:-$?}
  [[ "$cleanup_finished" == true ]] && return "$exit_code"
  cleanup_finished=true
  set +e
  [[ -n "$conflict_pid" ]] && kill "$conflict_pid" 2>/dev/null || true
  if [[ "$exit_code" -ne 0 ]]; then
    print -r -- "Failed phase: $last_phase" >>"$report"
    for response_path in "$runtime_root"/*.json(N); do
      jq -c 'select(type == "object" and (.code | type) == "string" and (.message | type) == "string") | {code,message}' \
        "$response_path" >>"$report" 2>/dev/null || true
    done
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
trap 'cleanup $?' EXIT
# zsh ERR_EXIT inside a function does not invoke a top-level EXIT trap.
# Clean only this run's resources before preserving the failing status.
TRAPZERR() {
  local failure_code=$?
  cleanup "$failure_code"
  exit "$failure_code"
}

fail() {
  if [[ -f "$runtime_root/connection-output.jsonl" ]]; then
    # These are bounded test-only status records, never connection credentials.
    tail -3 "$runtime_root/connection-output.jsonl" >>"$report"
  fi
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
chmod 700 "$runtime_root"
chmod 700 "$data_root"
mkdir -m 700 "$bootstrap_root"
[[ -d "$source_candidate" ]] || fail "The Build $build_number app candidate does not exist."
/usr/bin/ditto "$source_candidate" "$candidate"
[[ -x "$application" ]] || fail "The native Aurelia app is missing."
[[ -x "$helper" ]] || fail "The native server host helper is missing."
[[ -x "$server" ]] || fail "The embedded server for this Mac's architecture is missing."
if lsof -nP -iTCP:43110 -sTCP:LISTEN >/dev/null 2>&1; then
  fail "Loopback port 43110 is already occupied; no existing process was stopped."
fi

print -r -- "Aurelia Build $build_number native host smoke test" >"$report"
print -r -- "Run: $run_id" >>"$report"

lan_port="$(ruby -rsocket -e 'server = TCPServer.new("127.0.0.1", 0); puts server.addr[1]; server.close')"
open -n -g --env AURELIA_PREFLIGHT_TEST=1 --env "AURELIA_DATA_DIR=$data_root" \
  "$candidate" --args -AureliaOperatingMode client
for _ in {1..50}; do
  application_pid="$(pgrep -f "^$application( |$)" | tail -1 || true)"
  [[ -n "$application_pid" ]] && kill -0 "$application_pid" 2>/dev/null && break
  sleep 0.1
done
[[ -n "$application_pid" ]] && kill -0 "$application_pid" 2>/dev/null \
  || fail "The isolated parent Aurelia app did not start through Launch Services."

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
configure_body="$(jq -cn \
  --arg serverName 'Aurelia Host Smoke' --argjson lanHttpsPort "$lan_port" \
  '{version:1,serverName:$serverName,lanAccessEnabled:true,lanHttpsPort:$lanHttpsPort}')"
last_phase='initial configuration'
curl --silent --show-error --fail-with-body \
  --request POST --header 'Content-Type: application/json' --data "$configure_body" \
  "$control_base/configure" >"$runtime_root/configure-response.json"
setup_body="$(jq -cn \
  --arg username 'host-smoke-owner' \
  --arg password "$owner_password" \
  --arg deviceName 'Native Host Smoke' \
  '{username:$username,password:$password,deviceName:$deviceName}')"
last_phase='owner setup'
curl --silent --show-error --fail-with-body \
  --header 'Content-Type: application/json' \
  --header "X-Aurelia-Bootstrap-Token: $bootstrap" \
  --data "$setup_body" \
  'http://127.0.0.1:43110/api/v1/setup/owner' >"$runtime_root/authentication.json"

token="$(jq -r '.token // empty' "$runtime_root/authentication.json")"
[[ ${#token} -ge 43 ]] || fail "Owner setup did not return a device token."
device_token="$token"
owner_id="$(jq -er '.user.id' "$runtime_root/authentication.json")"
last_phase='LAN restart'
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
expected_fingerprint="$(openssl x509 -in "$data_root/server-certificate.pem" -pubkey -noout \
  | openssl pkey -pubin -outform DER | shasum -a 256 | awk '{print toupper($1)}')"
[[ "$reported_fingerprint" == "$expected_fingerprint" ]] || fail "The live certificate differs from the private synthetic server identity."
curl_pin="sha256//$(openssl x509 -in "$data_root/server-certificate.pem" -pubkey -noout \
  | openssl pkey -pubin -outform DER | openssl dgst -sha256 -binary | base64)"

unlock_viewing_and_management() {
  local unlock_body management_body
  unlock_body='{"pin":"1234"}'
  curl --silent --show-error --fail-with-body --insecure --pinnedpubkey "$curl_pin" \
    --header "Authorization: Bearer $device_token" --header 'Content-Type: application/json' \
    --data "$unlock_body" "$https_base/api/v1/profiles/$owner_id/unlock" >"$runtime_root/viewing.json"
  token="$(jq -er '.token' "$runtime_root/viewing.json")"
  management_body="$(jq -cn --arg password "$owner_password" '{password:$password}')"
  curl --silent --show-error --fail-with-body --insecure --pinnedpubkey "$curl_pin" \
    --header "Authorization: Bearer $token" --header 'Content-Type: application/json' \
    --data "$management_body" "$https_base/api/v1/management/unlock" >/dev/null
}

approved_post() {
  local action_path=$1 request_body=$2 approval_payload approval_token
  last_phase="password confirmation: $action_path"
  approval_payload="$(jq -cn --arg password "$owner_password" --arg action "POST $action_path" \
    --arg payloadHash "$(print -rn -- "$request_body" | shasum -a 256 | awk '{print toupper($1)}')" \
    '{password:$password,action:$action,payloadHash:$payloadHash}')"
  curl --silent --show-error --fail-with-body --insecure --pinnedpubkey "$curl_pin" \
    --header "Authorization: Bearer $token" --header 'Content-Type: application/json' \
    --data "$approval_payload" "$https_base/api/v1/server/approval" >"$runtime_root/operation-approval.json"
  approval_token="$(jq -r '.token' "$runtime_root/operation-approval.json")"
  last_phase="operation: $action_path"
  curl --silent --show-error --fail-with-body --insecure --pinnedpubkey "$curl_pin" \
    --header "Authorization: Bearer $token" --header "X-Aurelia-Approval: $approval_token" \
    --header 'Content-Type: application/json' --data "$request_body" "$https_base$action_path"
}

last_phase='separate device, PIN and management authorities'
locked_status="$(curl --silent --insecure --pinnedpubkey "$curl_pin" --output /dev/null --write-out '%{http_code}' \
  --header "Authorization: Bearer $device_token" "$https_base/api/v1/catalog/items")"
[[ "$locked_status" == 403 ]] || fail "A device credential exposed the catalog before PIN unlock."
initialize_body="$(jq -cn --arg password "$owner_password" '{password:$password,pin:"1234"}')"
curl --silent --show-error --fail-with-body --insecure --pinnedpubkey "$curl_pin" \
  --header "Authorization: Bearer $device_token" --header 'Content-Type: application/json' \
  --data "$initialize_body" "$https_base/api/v1/profiles/initialize" >/dev/null
unlock_viewing_and_management

curl --silent --show-error --fail-with-body --insecure \
  --pinnedpubkey "$curl_pin" \
  --header "Authorization: Bearer $token" \
  "$https_base/api/v1/auth/me" >"$runtime_root/me.json"
[[ "$(jq -r '.role // empty' "$runtime_root/me.json")" == owner ]] \
  || fail "The authenticated owner identity was not returned by /auth/me."

fixture="$runtime_root/Fixture Movies"
last_phase='synthetic library'
mkdir -p "$fixture"
dd if=/dev/zero of="$fixture/Host Smoke Movie 2026.mkv" bs=1024 count=1 status=none
library_body="$(jq -cn --arg path "$fixture" \
  '{path:$path,kind:"automatic"}')"
approval_body="$(jq -cn --arg password "$owner_password" --arg action 'POST /api/v1/libraries' \
  --arg payloadHash "$(print -rn -- "$library_body" | shasum -a 256 | awk '{print $1}')" \
  '{password:$password,action:$action,payloadHash:$payloadHash}')"
curl --silent --show-error --fail-with-body --insecure \
  --pinnedpubkey "$curl_pin" \
  --header "Authorization: Bearer $token" --header 'Content-Type: application/json' \
  --data "$approval_body" "$https_base/api/v1/server/approval" >"$runtime_root/approval.json"
approval="$(jq -r '.token' "$runtime_root/approval.json")"
curl --silent --show-error --fail-with-body --insecure \
  --pinnedpubkey "$curl_pin" \
  --header "X-Aurelia-Approval: $approval" \
  --header "Authorization: Bearer $token" --header 'Content-Type: application/json' \
  --data "$library_body" "$https_base/api/v1/libraries" >"$runtime_root/library.json"
library_id="$(jq -r '.id // empty' "$runtime_root/library.json")"
[[ -n "$library_id" ]] || fail "The test library was not created."
curl --silent --show-error --fail-with-body --insecure --request POST \
  --pinnedpubkey "$curl_pin" \
  --header "Authorization: Bearer $token" \
  "$https_base/api/v1/libraries/$library_id/scans" >"$runtime_root/scan.json"
scan_id="$(jq -r '.id // empty' "$runtime_root/scan.json")"
for _ in {1..100}; do
  curl --silent --show-error --fail-with-body --insecure \
    --pinnedpubkey "$curl_pin" \
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
  --pinnedpubkey "$curl_pin" \
  --header "Authorization: Bearer $token" \
  "$https_base/api/v1/catalog/items?kind=movie&offset=0&limit=10" \
  >"$runtime_root/catalog.json"
media_id="$(jq -r '.items[0].id // empty' "$runtime_root/catalog.json")"
[[ -n "$media_id" ]] || fail "The bounded test movie did not appear in the presentation catalog."
curl --silent --show-error --fail-with-body --insecure --request POST \
  --pinnedpubkey "$curl_pin" \
  --header "Authorization: Bearer $token" \
  "$https_base/api/v1/media/$media_id/playback" >"$runtime_root/playback.json"
stream_path="$(jq -r '.streamPath // empty' "$runtime_root/playback.json")"
[[ "$stream_path" == /api/v1/streams/* ]] || fail "Direct Play did not return a relative ticket URL."
range_status="$(curl --silent --insecure --output "$runtime_root/range.bin" \
  --pinnedpubkey "$curl_pin" \
  --write-out '%{http_code}' --header "Authorization: Bearer $token" --header 'Range: bytes=0-63' "$https_base$stream_path")"
[[ "$range_status" == 206 ]] || fail "Direct Play did not honor the bounded byte range."
[[ "$(stat -f '%z' "$runtime_root/range.bin")" == 64 ]] \
  || fail "Direct Play returned an unexpected byte count."

last_phase='packaged metadata editor and image processing'
/usr/bin/swift -warnings-as-errors -module-cache-path "$runtime_root/SwiftModules" -e '
import AppKit
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 60, pixelsHigh: 90,
  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let color = NSColor(calibratedRed: 0.1, green: 0.3, blue: 0.8, alpha: 1)
for y in 0..<90 { for x in 0..<60 { bitmap.setColor(color, atX: x, y: y) } }
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
' "$runtime_root/editor-source.png"
curl --silent --show-error --fail-with-body --insecure --pinnedpubkey "$curl_pin" \
  --header "Authorization: Bearer $token" \
  "$https_base/api/v1/media/$media_id/editor" >"$runtime_root/editor-before.json"
curl --silent --show-error --fail-with-body --insecure --pinnedpubkey "$curl_pin" \
  --header "Authorization: Bearer $token" --header 'Content-Type: image/png' \
  --data-binary "@$runtime_root/editor-source.png" \
  "$https_base/api/v1/media/$media_id/editor/uploads" >"$runtime_root/editor-upload.json"
editor_upload="$(jq -r '.id' "$runtime_root/editor-upload.json")"
editor_body="$(jq -c --arg upload "$editor_upload" --arg person "$(uuidgen)" \
  '{revision:.revision,values:(.values | .title="Edited Host Movie" | .releaseYear=2026 |
    .runtimeMinutes=98 | .fskAge=12 | .overview="" |
    .poster={uploadId:$upload,crop:{x:0,y:0,width:1,height:1,rotation:0}} |
    .credits=[{id:$person,name:"Synthetic Performer",department:"Acting",job:"Actor",
      character:"Host Character",profile:{uploadId:$upload}}]),
    overrideFields:["title","releaseYear","runtimeMinutes","fsk","overview","poster","credits"]}' \
  "$runtime_root/editor-before.json")"
curl --silent --show-error --fail-with-body --insecure --pinnedpubkey "$curl_pin" --request PUT \
  --header "Authorization: Bearer $token" --header 'Content-Type: application/json' \
  --data "$editor_body" "$https_base/api/v1/media/$media_id/editor" >"$runtime_root/editor-saved.json"
[[ "$(jq -r '.values.title' "$runtime_root/editor-saved.json")" == 'Edited Host Movie' \
  && "$(jq -r '.values.overview' "$runtime_root/editor-saved.json")" == '' \
  && "$(jq '.values.credits | length' "$runtime_root/editor-saved.json")" == 1 ]] \
  || fail "The packaged editor did not retain manual metadata and credits."
editor_asset="$(jq -r '.values.poster.assetId' "$runtime_root/editor-saved.json")"
curl --silent --show-error --fail-with-body --insecure --pinnedpubkey "$curl_pin" \
  --header "Authorization: Bearer $token" \
  "$https_base/api/v1/media/$media_id/editor/artwork/$editor_asset" >"$runtime_root/editor-original.png"
[[ "$(stat -f '%z' "$runtime_root/editor-original.png")" -gt 0 ]] \
  || fail "The packaged image processor did not retain the sanitized original."
editor_original_hash="$(shasum -a 256 "$runtime_root/editor-original.png" | awk '{print $1}')"
stale_status="$(curl --silent --insecure --pinnedpubkey "$curl_pin" --request PUT \
  --header "Authorization: Bearer $token" --header 'Content-Type: application/json' \
  --data "$editor_body" --output "$runtime_root/editor-conflict.json" --write-out '%{http_code}' \
  "$https_base/api/v1/media/$media_id/editor")"
[[ "$stale_status" == 409 ]] || fail "The packaged editor accepted a stale revision."

approved_post /api/v1/auth/pairings '' >"$runtime_root/pairing.json"
[[ "$(jq -r '.code // empty | length' "$runtime_root/pairing.json")" == 8 ]] \
  || fail "The server did not create an eight-digit pairing code."
curl --silent --show-error --fail-with-body --insecure \
  --pinnedpubkey "$curl_pin" \
  --header "Authorization: Bearer $token" \
  "$https_base/api/v1/auth/sessions" >"$runtime_root/sessions.json"
[[ "$(jq 'length' "$runtime_root/sessions.json")" -ge 1 ]] \
  || fail "The owner session was not listed."

wait_for_network() {
  local expected_name=$1
  for _ in {1..150}; do
    if curl --silent --insecure --pinnedpubkey "$curl_pin" --max-time 1 \
      "$https_base/api/v1/server/info" >"$runtime_root/server-info.json" 2>/dev/null \
      && [[ "$(jq -r '.name // empty' "$runtime_root/server-info.json")" == "$expected_name" ]]; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

curl --silent --show-error --fail-with-body --insecure --pinnedpubkey "$curl_pin" \
  --header "Authorization: Bearer $token" "$https_base/api/v1/server/settings" >"$runtime_root/settings.json"
trial_port="$(ruby -rsocket -e 'server = TCPServer.new("127.0.0.1", 0); puts server.addr[1]; server.close')"
trial_body="$(jq -c --argjson port "$trial_port" \
  '{settings:(.stored | .serverName="Confirmed Host Trial" | .lanHttpsPort=$port | .bonjourEnabled=false),confirmRemoteAccessDisabled:false}' \
  "$runtime_root/settings.json")"
approved_post /api/v1/server/operations/network "$trial_body" >"$runtime_root/trial.json"
trial_id="$(jq -r '.id' "$runtime_root/trial.json")"
https_base="https://127.0.0.1:$trial_port"
wait_for_network 'Confirmed Host Trial' || fail "The new network configuration did not become reachable."
unlock_viewing_and_management
curl --silent --show-error --fail-with-body --insecure --pinnedpubkey "$curl_pin" --request POST \
  --header "Authorization: Bearer $token" "$https_base/api/v1/server/operations/$trial_id/confirm" >/dev/null
[[ "$(jq -r '.state' "$data_root/host-operation.json")" == completed ]] || fail "The network trial was not confirmed."
[[ "$(jq -r '.publicKeyFingerprint' "$runtime_root/server-info.json")" == "$reported_fingerprint" ]] \
  || fail "A network change replaced the TLS identity."

curl --silent --show-error --fail-with-body --insecure --pinnedpubkey "$curl_pin" \
  --header "Authorization: Bearer $token" "$https_base/api/v1/server/settings" >"$runtime_root/settings.json"
trial_body="$(jq -c '{settings:(.stored | .serverName="Unconfirmed Host Trial"),confirmRemoteAccessDisabled:false}' "$runtime_root/settings.json")"
approved_post /api/v1/server/operations/network "$trial_body" >"$runtime_root/trial.json"
wait_for_network 'Unconfirmed Host Trial' || fail "The unconfirmed network trial was not applied."
for _ in {1..140}; do
  [[ "$(jq -r '.state' "$data_root/host-operation.json")" == rolledBack ]] && break
  sleep 0.5
done
[[ "$(jq -r '.state' "$data_root/host-operation.json")" == rolledBack ]] || fail "The unconfirmed network did not roll back after 60 seconds."
wait_for_network 'Confirmed Host Trial' || fail "The previous network did not return after rollback."
unlock_viewing_and_management

note_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
curl --silent --show-error --fail-with-body --insecure --pinnedpubkey "$curl_pin" --request PUT \
  --header "Authorization: Bearer $token" --header 'Content-Type: application/json' \
  --data '{"startMilliseconds":15000,"endMilliseconds":19000,"text":"Synthetic private scene note","revision":0}' \
  "$https_base/api/v1/media/$media_id/notes/$note_id" >"$runtime_root/scene-note.json"
[[ "$(jq -r '.revision' "$runtime_root/scene-note.json")" == 1 ]] || fail "A private note was not saved before backup."

approved_post /api/v1/server/backups/export '{"passphrase":"isolated full backup passphrase"}' >"$runtime_root/export.json"
export_id="$(jq -r '.id' "$runtime_root/export.json")"
[[ "$(jq -r '.includesMedia' "$runtime_root/export.json")" == false ]] || fail "Full backup unexpectedly included media."
restore_body="$(jq -cn --arg uploadId "$export_id" \
  '{uploadId:$uploadId,passphrase:"isolated full backup passphrase",revokeAllSessions:true,acceptDifferentServerIdentity:false}')"
approved_post /api/v1/server/backups/restore/prepare "$restore_body" >"$runtime_root/prepared.json"
restore_id="$(jq -r '.id' "$runtime_root/prepared.json")"
approved_post "/api/v1/server/backups/restore/$restore_id/apply" '' >"$runtime_root/restore-operation.json"
for _ in {1..120}; do
  operation_state="$(jq -r '.state // empty' "$data_root/host-operation.json")"
  [[ "$operation_state" == completed ]] && break
  [[ "$operation_state" == failed ]] && fail "The prepared full restore failed in the native host."
  sleep 0.25
done
[[ "$(jq -r '.state' "$data_root/host-operation.json")" == completed ]] || fail "The native full restore timed out."
wait_for_network 'Confirmed Host Trial' || fail "The restored server was not reachable."
revoked_status="$(curl --silent --insecure --pinnedpubkey "$curl_pin" --output /dev/null --write-out '%{http_code}' \
  --header "Authorization: Bearer $token" "$https_base/api/v1/auth/me")"
[[ "$revoked_status" == 401 ]] || fail "Restore made the old device token valid again."
revoked_device_status="$(curl --silent --insecure --pinnedpubkey "$curl_pin" --output /dev/null --write-out '%{http_code}' \
  --header "Authorization: Bearer $device_token" "$https_base/api/v1/profiles")"
[[ "$revoked_device_status" == 401 ]] || fail "Restore reactivated the old paired device."
curl --silent --show-error --fail-with-body --insecure --pinnedpubkey "$curl_pin" --header 'Content-Type: application/json' \
  --data "$setup_body" "$https_base/api/v1/auth/login" >"$runtime_root/restored-authentication.json"
token="$(jq -r '.token' "$runtime_root/restored-authentication.json")"
[[ ${#token} -ge 43 ]] || fail "The owner could not sign in after restore."
device_token="$token"
unlock_viewing_and_management
curl --silent --show-error --fail-with-body --insecure --pinnedpubkey "$curl_pin" \
  --header "Authorization: Bearer $token" "$https_base/api/v1/media/$media_id/notes" >"$runtime_root/restored-notes.json"
jq -e --arg id "$note_id" 'length == 1 and .[0].id == $id and .[0].revision == 1 and .[0].text == "Synthetic private scene note"' \
  "$runtime_root/restored-notes.json" >/dev/null || fail "Restore lost private scene note identity, revision or text."
[[ "$(jq -r '.publicKeyFingerprint' "$runtime_root/server-info.json")" == "$reported_fingerprint" ]] || fail "Restore lost the existing TLS identity."
[[ "$(sqlite3 "$data_root/aurelia.db" 'SELECT count(*) FROM LibraryRoots;')" == 1 ]] || fail "The isolated library was not restored."
curl --silent --show-error --fail-with-body --insecure --pinnedpubkey "$curl_pin" \
  --header "Authorization: Bearer $token" \
  "$https_base/api/v1/media/$media_id/editor" >"$runtime_root/editor-restored.json"
[[ "$(jq -r '.values.title' "$runtime_root/editor-restored.json")" == 'Edited Host Movie' \
  && "$(jq -r '.values.poster.assetId' "$runtime_root/editor-restored.json")" == "$editor_asset" ]] \
  || fail "Full restore lost manual metadata or image identity."
curl --silent --show-error --fail-with-body --insecure --pinnedpubkey "$curl_pin" \
  --header "Authorization: Bearer $token" \
  "$https_base/api/v1/media/$media_id/editor/artwork/$editor_asset" >"$runtime_root/editor-restored-original.png"
[[ "$(shasum -a 256 "$runtime_root/editor-restored-original.png" | awk '{print $1}')" == "$editor_original_hash" ]] \
  || fail "Full restore changed or lost the imported original image."

# A deliberately occupied HTTPS port is isolated to this test's child process.
ruby -rsocket -e 'server=TCPServer.new("0.0.0.0",0); STDOUT.sync=true; puts server.addr[1]; sleep 180' >"$runtime_root/conflict-port.txt" &
conflict_pid=$!
for _ in {1..30}; do
  [[ -s "$runtime_root/conflict-port.txt" ]] && break
  sleep 0.1
done
conflict_port="$(<"$runtime_root/conflict-port.txt")"
curl --silent --show-error --fail-with-body --insecure --pinnedpubkey "$curl_pin" \
  --header "Authorization: Bearer $token" "$https_base/api/v1/server/settings" >"$runtime_root/settings.json"
trial_body="$(jq -c --argjson port "$conflict_port" \
  '{settings:(.stored | .lanHttpsPort=$port),confirmRemoteAccessDisabled:false}' "$runtime_root/settings.json")"
approved_post /api/v1/server/operations/network "$trial_body" >"$runtime_root/trial.json"
for _ in {1..140}; do
  [[ "$(jq -r '.state' "$data_root/host-operation.json")" == rolledBack ]] && break
  sleep 0.5
done
[[ "$(jq -r '.state' "$data_root/host-operation.json")" == rolledBack ]] || fail "The occupied-port trial did not roll back."
wait_for_network 'Confirmed Host Trial' || fail "The host did not recover from the HTTPS port conflict."
kill "$conflict_pid"
wait "$conflict_pid" 2>/dev/null || true
conflict_pid=''

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

last_phase='saved local connection recovery'
jq -cn --slurpfile info "$runtime_root/server-info.json" \
  --slurpfile auth "$runtime_root/restored-authentication.json" --arg baseURL "$https_base" \
  '{serverId:$info[0].serverId,name:$info[0].name,baseURL:$baseURL,publicKeyFingerprint:$info[0].publicKeyFingerprint,
    token:$auth[0].token,sessionId:$auth[0].sessionId,expiresAt:$auth[0].expiresAt,user:$auth[0].user}' \
  >"$data_root/connection.json"
chmod 600 "$data_root/connection.json"
connection_before="$(jq -cS 'del(.locallyManaged)' "$data_root/connection.json")"
connection_log_start=''

wait_for_connection_result() {
  local expected=$1
  for _ in {1..300}; do
    /usr/bin/log show --start "$connection_log_start" --style compact \
      --predicate "processIdentifier == $application_pid AND eventMessage BEGINSWITH 'IsolatedHostResult '" \
      2>/dev/null | sed -n 's/.*IsolatedHostResult \({.*}\).*/\1/p' >"$runtime_root/connection-output.jsonl"
    [[ -s "$runtime_root/connection-output.jsonl" ]] \
      && [[ "$(tail -1 "$runtime_root/connection-output.jsonl" | jq -r '.ready' 2>/dev/null)" == "$expected" ]] && return 0
    sleep 0.1
  done
  return 1
}

for requested_mode in host client; do
  rm -f "$runtime_root/connection-output.jsonl"
  # Count this app instance's results from a fixed boundary. A sliding one-minute
  # window loses earlier successes during three legitimate delayed recoveries.
  connection_log_start="$(date '+%Y-%m-%d %H:%M:%S')"
  if [[ "$requested_mode" == client ]]; then
    jq '. + {locallyManaged:true}' "$data_root/connection.json" >"$data_root/connection-next.json"
    mv "$data_root/connection-next.json" "$data_root/connection.json"
  fi
  open -n -g --env AURELIA_PREFLIGHT_TEST=1 --env AURELIA_PREFLIGHT_CONNECTION_TEST=1 \
    --env "AURELIA_DATA_DIR=$data_root" --env "AURELIA_LOG_DIR=$host_log_root" \
    --env "AURELIA_PREFLIGHT_PROFILE=$(jq -c . "$data_root/connection.json")" \
    --stdout "$runtime_root/connection-output.jsonl" \
    "$candidate" --args -ApplePersistenceIgnoreState YES \
    -AureliaOperatingMode "$requested_mode" -AureliaOperatingModeSelectionVersion 1
  for _ in {1..100}; do
    application_pid="$(pgrep -f "^$application( |$)" | tail -1 || true)"
    [[ -n "$application_pid" ]] && break
    sleep 0.1
  done
  wait_for_connection_result true || fail "Saved connection did not finish starting."
  [[ "$(tail -1 "$runtime_root/connection-output.jsonl" | jq -r '.ready and .owned and .unchangedConnection and .viewingLocked and (.profilesCount > 0) and (.catalogCount == 0)')" == true ]] \
    || fail "Saved local device did not show profiles without exposing private catalog data."
  [[ "$(jq -cS 'del(.locallyManaged)' "$data_root/connection.json")" == "$connection_before" ]] \
    || fail "Recovery changed the saved account, session, address, or TLS identity."
  helper_pid="$(pgrep -f "^$helper( |$)" | tail -1 || true)"
  [[ -n "$helper_pid" ]] || fail "Restored app has no owned helper."
  if [[ "$requested_mode" == client ]]; then
    last_phase='bounded automatic host recovery'
    for recovery_attempt in {1..3}; do
      previous_helper_pid="$helper_pid"
      previous_result_count="$(wc -l <"$runtime_root/connection-output.jsonl")"
      kill -KILL "$helper_pid"
      for _ in {1..300}; do
        /usr/bin/log show --start "$connection_log_start" --style compact \
          --predicate "processIdentifier == $application_pid AND eventMessage BEGINSWITH 'IsolatedHostResult '" \
          2>/dev/null | sed -n 's/.*IsolatedHostResult \({.*}\).*/\1/p' >"$runtime_root/connection-output.jsonl"
        [[ "$(wc -l <"$runtime_root/connection-output.jsonl")" -gt "$previous_result_count" ]] && break
        sleep 0.1
      done
      [[ "$(wc -l <"$runtime_root/connection-output.jsonl")" -gt "$previous_result_count" ]] \
        || fail "Unexpected helper exit was not recovered on attempt $recovery_attempt."
      [[ "$(tail -1 "$runtime_root/connection-output.jsonl" | jq -r '.ready and .owned and .unchangedConnection and .viewingLocked and (.profilesCount > 0) and (.catalogCount == 0)')" == true ]] \
        || fail "Automatic recovery lost the paired device or bypassed profile PIN selection."
      helper_pid="$(pgrep -f "^$helper( |$)" | tail -1 || true)"
      [[ -n "$helper_pid" && "$helper_pid" != "$previous_helper_pid" ]] \
        || fail "Automatic recovery did not create a fresh owned helper."
    done
    kill -TERM "$helper_pid"
    wait_for_connection_result false || fail "Persistent host failure was not reported after three recoveries."
    [[ "$(tail -1 "$runtime_root/connection-output.jsonl" | jq -r '.ready')" == false ]] \
      || fail "Recovery restarted repeatedly instead of reporting a persistent problem."
    sleep 2
    [[ -z "$(pgrep -f "^$helper( |$)" || true)" ]] || fail "Automatic recovery exceeded its three-attempt budget."
    helper_pid=''
  fi
  /usr/bin/swift -e 'import AppKit; guard let pid = Int32(CommandLine.arguments[1]), let app = NSRunningApplication(processIdentifier: pid), app.terminate() else { exit(1) }' "$application_pid"
  for _ in {1..150}; do
    kill -0 "$application_pid" 2>/dev/null || break
    sleep 0.1
  done
  kill -0 "$application_pid" 2>/dev/null && fail "Recovered app did not quit cleanly."
  application_pid=''
  for _ in {1..100}; do
    [[ -z "$helper_pid" ]] || ! kill -0 "$helper_pid" 2>/dev/null && break
    sleep 0.1
  done
  helper_pid=''
done

if [[ -f "$host_log_root/server.log" ]]; then
  cp "$host_log_root/server.log" "$copied_log"
fi
{
  print -r -- "PASS: helper control channel rejected an invalid secret"
  print -r -- "PASS: one-time owner bootstrap and LAN HTTPS restart"
  print -r -- "PASS: live TLS public-key fingerprint matched server identity"
  print -r -- "PASS: /auth/me, library creation, bounded scan, pairing, and sessions"
  print -r -- "PASS: paired device could not read catalog; explicit PIN and separate management unlock required"
  print -r -- "PASS: authenticated Direct Play returned the requested 64-byte original-file range"
  print -r -- "PASS: packaged metadata editor imported/cropped an image, saved credits/manual blanks, and rejected stale revisions"
  print -r -- "PASS: confirmed network change retained TLS identity and device sessions"
  print -r -- "PASS: unconfirmed network change rolled back after 60 seconds"
  print -r -- "PASS: native encrypted restore retained library/TLS identity and revoked old tokens"
  print -r -- "PASS: encrypted full restore retained manual metadata and imported image identity/bytes"
  print -r -- "PASS: encrypted full restore retained profile PIN and private scene note identity/revision/text"
  print -r -- "PASS: occupied HTTPS port rolled back to the reachable previous network"
  print -r -- "PASS: graceful helper/server shutdown"
  print -r -- "PASS: helper stopped when its isolated PID-bound parent app disappeared"
  print -r -- "PASS: legacy local connection gained verified ownership without changing its session or identity"
  print -r -- "PASS: stale explicit client preference retained device and required PIN at app relaunch"
  print -r -- "PASS: three unexpected helper exits retained paired device and PIN-gated profile selection; a fourth stopped without a restart loop"
  print -r -- "PASS: SQLite quick_check and integrity_check; foreign keys clean"
  print -r -- "PASS: bounded logs contain no tested secrets"
} >>"$report"

print -r -- "Native host smoke test passed. Report: $report"
