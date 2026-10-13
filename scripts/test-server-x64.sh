#!/bin/zsh
set -euo pipefail

# Execute the signed Intel payload under Rosetta; never use installed/user data.
repository_root=${0:A:h:h}
source "$repository_root/scripts/workspace-paths.sh"
build_number=$(sed -n 's:.*<AureliaBuildNumber>\([0-9][0-9]*\)</AureliaBuildNumber>.*:\1:p' "$repository_root/Directory.Build.props")
candidate=${1:-"$other_root/Build/Build $build_number/Aurelia.app"}
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$(uuidgen | tr '[:upper:]' '[:lower:]')"
run_root="/private/tmp/Aurelia/$run_id"
server_root="$run_root/Intel Server"
data_root="$run_root/Data"
report="$other_root/Test Results/Aurelia-IntelServer-$run_id.txt"
server_pid=''
cleanup() {
  local code=$?
  set +e
  if [[ -n "$server_pid" ]]; then
    kill -TERM "$server_pid" 2>/dev/null
    wait "$server_pid" 2>/dev/null
  fi
  if [[ "$code" -ne 0 && -f "$run_root/server.log" ]]; then
    cp "$run_root/server.log" "$other_root/Logs/Aurelia-IntelServer-$run_id.log"
  fi
  [[ "$run_root" == /private/tmp/Aurelia/* ]] && find "$run_root" -depth -delete
  return "$code"
}
trap cleanup EXIT
fail() { print -r -- "FAIL: $1" | tee -a "$report" >&2; exit 1; }

mkdir -p "$run_root" "$data_root" "$other_root/Test Results" "$other_root/Logs"
chmod 700 "$run_root" "$data_root"
print -r -- "Aurelia Build $build_number signed Intel server smoke (Rosetta on Apple Silicon)" >"$report"
/usr/bin/arch -x86_64 /usr/bin/true || fail "Intel execution is unavailable; Rosetta was not installed by this test."
[[ -x "$candidate/Contents/Resources/Server/osx-x64/Aurelia.Server" ]] || fail "The Intel payload is missing."
/usr/bin/ditto "$candidate/Contents/Resources/Server/osx-x64" "$server_root"
port=$(ruby -rsocket -e 'socket=TCPServer.new("127.0.0.1",0); puts socket.addr[1]; socket.close')
base="http://127.0.0.1:$port"
bootstrap=$(openssl rand -base64 32 | tr -d '\n')
AURELIA_BOOTSTRAP_TOKEN="$bootstrap" AURELIA_LAN_ENABLED=false \
  /usr/bin/arch -x86_64 "$server_root/Aurelia.Server" run --data-dir "$data_root" --urls "$base" \
  >"$run_root/server.log" 2>&1 &
server_pid=$!
server_ready=false
# A freshly copied, signed Intel runtime took 52 seconds to become ready in
# a cold Rosetta probe. Allow a bounded 90-second startup observation without
# weakening setup, authentication, scan, editor, or integrity assertions.
readiness_deadline=$((SECONDS + 90))
while (( SECONDS < readiness_deadline )); do
  if curl --silent --fail --max-time 1 "$base/api/v1/server/info" >"$run_root/info.json"; then
    server_ready=true
    break
  fi
  kill -0 "$server_pid" 2>/dev/null || fail "The Intel server exited before becoming ready."
  sleep 0.2
done
[[ "$server_ready" == true ]] || fail "The Intel server did not become ready during the bounded startup observation."
[[ "$(jq -r '.isSetup' "$run_root/info.json")" == false ]] || fail "The isolated server did not offer first-owner setup."
curl --silent --show-error --fail-with-body --header "X-Aurelia-Bootstrap-Token: $bootstrap" \
  --header 'Content-Type: application/json' \
  --data '{"username":"intel-test-owner","password":"isolated-intel-password-123!","deviceName":"Intel Payload Test"}' \
  "$base/api/v1/setup/owner" >"$run_root/auth.json"
device_token=$(jq -r '.token' "$run_root/auth.json")
owner_id=$(jq -r '.user.id' "$run_root/auth.json")
[[ ${#device_token} -ge 43 ]] || fail "The isolated owner was not paired."
# The isolated loopback transport is not a remote PIN connection. Production
# clients unlock over pinned HTTPS; the separate native-host smoke checks that.
curl --silent --show-error --fail-with-body --header "Authorization: Bearer $device_token" \
  --header 'Content-Type: application/json' \
  --data '{"password":"isolated-intel-password-123!","pin":"1234"}' \
  "$base/api/v1/profiles/initialize" >/dev/null
curl --silent --show-error --fail-with-body --header "Authorization: Bearer $device_token" \
  --header 'Content-Type: application/json' --data '{"pin":"1234"}' \
  "$base/api/v1/profiles/$owner_id/unlock" >"$run_root/viewing.json"
token=$(jq -er '.token' "$run_root/viewing.json")
curl --silent --show-error --fail-with-body --header "Authorization: Bearer $token" \
  --header 'Content-Type: application/json' --data '{"password":"isolated-intel-password-123!"}' \
  "$base/api/v1/management/unlock" >/dev/null
fixture="$run_root/Fixture"
mkdir -p "$fixture"
dd if=/dev/zero of="$fixture/Intel Movie 2026.mkv" bs=1024 count=1 status=none
body=$(jq -cn --arg path "$fixture" '{path:$path,kind:"automatic"}')
approval_body=$(jq -cn --arg hash "$(print -rn -- "$body" | shasum -a 256 | awk '{print $1}')" \
  '{password:"isolated-intel-password-123!",action:"POST /api/v1/libraries",payloadHash:$hash}')
curl --silent --show-error --fail-with-body --header "Authorization: Bearer $token" \
  --header 'Content-Type: application/json' --data "$approval_body" "$base/api/v1/server/approval" >"$run_root/approval.json"
curl --silent --show-error --fail-with-body --header "Authorization: Bearer $token" \
  --header "X-Aurelia-Approval: $(jq -r '.token' "$run_root/approval.json")" \
  --header 'Content-Type: application/json' --data "$body" "$base/api/v1/libraries" >"$run_root/library.json"
library=$(jq -r '.id' "$run_root/library.json")
curl --silent --show-error --fail-with-body --request POST --header "Authorization: Bearer $token" \
  "$base/api/v1/libraries/$library/scans" >"$run_root/scan.json"
scan=$(jq -r '.id' "$run_root/scan.json")
for _ in {1..150}; do
  curl --silent --show-error --fail-with-body --header "Authorization: Bearer $token" \
    "$base/api/v1/scans/$scan" >"$run_root/scan.json"
  [[ "$(jq -r '.state' "$run_root/scan.json")" == completed ]] && break
  sleep 0.2
done
[[ "$(jq -r '.state' "$run_root/scan.json")" == completed ]] || fail "The isolated scan did not complete."
curl --silent --show-error --fail-with-body --header "Authorization: Bearer $token" \
  "$base/api/v1/catalog/items?kind=movie&offset=0&limit=10" >"$run_root/catalog.json"
media=$(jq -r '.items[0].id' "$run_root/catalog.json")
/usr/bin/swift -warnings-as-errors -module-cache-path "$run_root/SwiftModules" -e '
import AppKit
let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:60,pixelsHigh:90,
 bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
let color=NSColor(calibratedRed:0.1,green:0.3,blue:0.8,alpha:1)
for y in 0..<90 { for x in 0..<60 { bitmap.setColor(color,atX:x,y:y) } }
try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
' "$run_root/source.png"
curl --silent --show-error --fail-with-body --header "Authorization: Bearer $token" \
  --header 'Content-Type: image/png' --data-binary "@$run_root/source.png" \
  "$base/api/v1/media/$media/editor/uploads" >"$run_root/upload.json"
curl --silent --show-error --fail-with-body --header "Authorization: Bearer $token" \
  "$base/api/v1/media/$media/editor" >"$run_root/editor.json"
body=$(jq -c --arg upload "$(jq -r '.id' "$run_root/upload.json")" \
  '{revision:.revision,values:(.values|.title="Intel Edited Title"|.poster={uploadId:$upload}),overrideFields:["title","poster"]}' "$run_root/editor.json")
curl --silent --show-error --fail-with-body --request PUT --header "Authorization: Bearer $token" \
  --header 'Content-Type: application/json' --data "$body" "$base/api/v1/media/$media/editor" >"$run_root/saved.json"
[[ "$(jq -r '.values.title' "$run_root/saved.json")" == 'Intel Edited Title' \
  && "$(jq -r '.values.poster.assetId' "$run_root/saved.json")" != null ]] \
  || fail "The Intel SkiaSharp/editor path did not save the imported image."
kill -TERM "$server_pid"
wait "$server_pid"
server_pid=''
[[ "$(sqlite3 "$data_root/aurelia.db" 'PRAGMA quick_check;')" == ok ]] || fail "Intel database integrity check failed."
print -r -- "PASS: signed x86_64 runtime started under Rosetta, migrated isolated data, authenticated, scanned, imported/cropped PNG with SkiaSharp, and saved metadata." >>"$report"
print -r -- "Intel server smoke test passed. Report: $report"
