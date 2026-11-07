#!/bin/zsh
set -euo pipefail
umask 077

# Run only after the synthetic full-chain gate, with human approval for the
# sole exact source supplied in AURELIA_AUTHORIZED_MEDIA_FILE. Never discover it
# by scanning folders. No file bytes are read before the bounded playback test.
# Usage: AURELIA_AUTHORIZED_PLAYBACK=BREAKING_BAD_S01E01_10_MINUTES \
#   AURELIA_AUTHORIZED_MEDIA_FILE='/exact/approved/source' \
#   AURELIA_CANDIDATE_CLIENT_SOURCE_FINGERPRINT='<captured before candidate build>' \
#   zsh scripts/test-playback-authorized-source.sh /path/to/signed/fixed/Aurelia.app
repository_root=${0:A:h:h}
source "$repository_root/scripts/workspace-paths.sh"
source "$repository_root/scripts/playback-evidence-common.sh"
candidate=${1:-}
[[ $# == 1 && -d "$candidate/Contents" \
  && "${AURELIA_AUTHORIZED_PLAYBACK:-}" == BREAKING_BAD_S01E01_10_MINUTES \
  && -n "${AURELIA_AUTHORIZED_MEDIA_FILE:-}" \
  && ${#AURELIA_CANDIDATE_CLIENT_SOURCE_FINGERPRINT:-0} == 64 \
  && "${AURELIA_CANDIDATE_CLIENT_SOURCE_FINGERPRINT:-}" != *[^A-F0-9]* ]] \
  || { evidence_fail exact_source_and_explicit_bounded_authorization_required; exit 2; }
candidate=${candidate:A}
configuration=${AURELIA_SOURCE_EVIDENCE_CONFIGURATION:-Release}
[[ "$configuration" == Release || "$configuration" == Debug ]] \
  || { evidence_fail invalid_source_evidence_configuration; exit 2; }
architecture=$(uname -m)
runtime='osx-arm64'
[[ "$(uname -m)" == x86_64 ]] && runtime='osx-x64'
[[ "$architecture" == arm64 || "$architecture" == x86_64 ]] || { evidence_fail unsupported_local_architecture; exit 2; }
server="$candidate/Contents/Resources/Server/$runtime/Aurelia.Server"
[[ -x "$server" && -x "$DOTNET_BIN" ]] \
  || { evidence_fail packaged_server_or_pinned_dotnet_unavailable; exit 2; }
runtime_parent="$HOME/Library/Caches/Aurelia/TestRuns"
mkdir -p "$runtime_parent" "$other_root/Test Results" "$other_root/Logs"
EVIDENCE_RUN_ROOT=$(mktemp -d "$runtime_parent/playback-evidence-authorized-XXXXXXXX")
export EVIDENCE_RUN_ROOT AURELIA_AUTHORIZED_MEDIA_FILE AURELIA_AUTHORIZED_PLAYBACK
run_id=${EVIDENCE_RUN_ROOT:t}
server_data="$EVIDENCE_RUN_ROOT/ServerData"
source_root="$EVIDENCE_RUN_ROOT/Source"
provisioner_publish="$EVIDENCE_RUN_ROOT/Provisioner"
derived_data="$EVIDENCE_RUN_ROOT/DerivedData"
result="$EVIDENCE_RUN_ROOT/Playback-Authorized-Source.xcresult"
result_prefix="Aurelia-Playback-Authorized-Source-$run_id"
final_result="$other_root/Test Results/$result_prefix.xcresult"
final_summary="$other_root/Test Results/$result_prefix.json"
server_pid=''
EVIDENCE_TOOL_PID=''
EVIDENCE_WATCHDOG_PID=''
EVIDENCE_FORCED_SHUTDOWN=false
last_phase='configuration'
test_attempted=false
test_executed=false
test_exit_code=null
source_metadata_unchanged=false
owned_progress_rows_zero=false
source_provenance_verified=false
signed_sandbox_verified=false
test_debugger_allowance_verified=false
mkdir -p "$server_data" "$source_root"
server_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$candidate/Contents/Info.plist")

finish() {
  local exit_code=$? cleanup_failed=false log_name deadline_reached=false watchdog_guard_failed=false
  set +e
  # Keep the independent read ceiling alive until this exact source server is
  # confirmed stopped. Cleanup of a hung test host may itself need ten seconds.
  if [[ -n "$server_pid" ]]; then
    evidence_stop_packaged_server "$server_pid" "$server" "$server_data" "$EVIDENCE_RUN_ROOT" \
      || cleanup_failed=true
  fi
  if [[ -n "$EVIDENCE_TOOL_PID" ]]; then
    evidence_stop_pid "$EVIDENCE_TOOL_PID" || cleanup_failed=true
  fi
  evidence_stop_test_hosts || cleanup_failed=true
  if [[ -n "$EVIDENCE_WATCHDOG_PID" ]]; then
    watchdog_state=$(ps -p "$EVIDENCE_WATCHDOG_PID" -o stat= 2>/dev/null || true)
    if [[ -z "$watchdog_state" || "$watchdog_state" == Z* \
      || -f "$EVIDENCE_RUN_ROOT/source-read-watchdog-failed.private" ]]; then
      cleanup_failed=true
      watchdog_guard_failed=true
    fi
    evidence_stop_pid "$EVIDENCE_WATCHDOG_PID" || cleanup_failed=true
  fi
  [[ ! -f "$EVIDENCE_RUN_ROOT/source-read-deadline.private" ]] || deadline_reached=true
  if [[ -f "$EVIDENCE_RUN_ROOT/source-before.private.json" ]]; then
    ruby "$repository_root/tools/macos/authorized-playback-source-metadata.rb" after \
      "$EVIDENCE_RUN_ROOT/source-after.private.json"
    if [[ $? == 0 ]] && cmp -s "$EVIDENCE_RUN_ROOT/source-before.private.json" \
      "$EVIDENCE_RUN_ROOT/source-after.private.json"; then
      source_metadata_unchanged=true
    else
      cleanup_failed=true
    fi
  fi
  if [[ -f "$server_data/aurelia.db" ]]; then
    progress_rows=$(/usr/bin/sqlite3 -readonly "$server_data/aurelia.db" \
      'SELECT count(*) FROM PlaybackProgress;' 2>"$EVIDENCE_RUN_ROOT/progress-check.private.log")
    if [[ $? == 0 && "$progress_rows" == 0 ]]; then
      owned_progress_rows_zero=true
    else
      cleanup_failed=true
    fi
  fi
  [[ ! -d "$result" ]] || /usr/bin/ditto "$result" "$final_result" || cleanup_failed=true
  for log_name in provisioner-build xcodebuild; do
    if [[ -f "$EVIDENCE_RUN_ROOT/$log_name.private.log" ]]; then
      evidence_export_log "$EVIDENCE_RUN_ROOT/$log_name.private.log" \
        "$other_root/Logs/$result_prefix-$log_name.log" \
        "$EVIDENCE_RUN_ROOT/authentication.private.json" || cleanup_failed=true
    fi
  done
  [[ "$cleanup_failed" == false && "$deadline_reached" == false ]] || exit_code=1
  # Only the explicitly permitted size/mtime metadata is retained, never the
  # authorized filename/path, inode, media bytes, credentials or personal state.
  metadata_files=()
  for moment in before after; do
    metadata_file="$EVIDENCE_RUN_ROOT/source-$moment.private.json"
    if [[ -f "$metadata_file" ]]; then
      jq '{size,modifiedSeconds,modifiedNanoseconds}' "$metadata_file" \
        >"$EVIDENCE_RUN_ROOT/public-$moment.private.json"
    else
      print -r -- 'null' >"$EVIDENCE_RUN_ROOT/public-$moment.private.json"
    fi
    metadata_files+=("$EVIDENCE_RUN_ROOT/public-$moment.private.json")
  done
  jq -s '.' "${metadata_files[@]}" >"$EVIDENCE_RUN_ROOT/public-metadata.private.json"
  jq -n --arg phase "$last_phase" --arg version "$server_version" \
    --arg architecture "$runtime" --arg configuration "$configuration" --argjson exitCode "$exit_code" \
    --argjson testAttempted "$test_attempted" --argjson testExecuted "$test_executed" \
    --argjson testExitCode "$test_exit_code" \
    --argjson sourceMetadataUnchanged "$source_metadata_unchanged" \
    --argjson ownedProgressRowsZero "$owned_progress_rows_zero" \
    --argjson clientSourceProvenanceVerified "$source_provenance_verified" \
    --argjson signedSandboxVerified "$signed_sandbox_verified" \
    --argjson testDebuggerAllowanceVerified "$test_debugger_allowance_verified" \
    --argjson forcedShutdown "$EVIDENCE_FORCED_SHUTDOWN" \
    --argjson externalReadDeadlineReached "$deadline_reached" \
    --argjson watchdogGuardFailed "$watchdog_guard_failed" \
    --argjson cleanupFailed "$cleanup_failed" \
    --slurpfile metadata "$EVIDENCE_RUN_ROOT/public-metadata.private.json" \
    '{formatVersion:2,passed:($exitCode==0 and $testExecuted),phase:$phase,version:$version,
      exitCode:$exitCode,testAttempted:$testAttempted,testExecuted:$testExecuted,testExitCode:$testExitCode,
      architecture:$architecture,clientConfiguration:$configuration,requiredPositionMilliseconds:405000,
      targetPositionMilliseconds:430000,
      approvedMaximumSourceReadSeconds:600,internalSourceReadDeadlineSeconds:570,
      externalSourceServerKillDeadlineSeconds:585,externalReadDeadlineReached:$externalReadDeadlineReached,
      watchdogGuardFailed:$watchdogGuardFailed,
      sourceMetadataBefore:$metadata[0][0],sourceMetadataAfter:$metadata[0][1],
      sourceSizeAndModificationTimeUnchanged:$sourceMetadataUnchanged,
      disposableDatabaseProgressRowsZero:$ownedProgressRowsZero,
      clientCodeAndCompilerConfigurationProvenanceVerified:$clientSourceProvenanceVerified,
      actualSignedHostSandboxVerified:$signedSandboxVerified,
      testHostDebuggerAllowanceVerified:$testDebuggerAllowanceVerified,
      forcedShutdown:$forcedShutdown,cleanupFailed:$cleanupFailed,
      personalProgressPreservation:"Never connects to the personal server or instantiates a progress writer; all tickets/accounts/catalog state belong to a disposable database. The isolated progress snapshot is checked by the test, and its progress table remains empty.",
      sourcePolicy:"Only the explicitly supplied canonical regular source is opened, read-only and in place, for bounded playback. No copy, conversion, hash, frame/audio capture, content analysis or directory scan.",
      isolation:"AppModel fails closed in the TestRuns host before saved account/host settings; the test constructs real pinned API/relay/VLC directly. Sandbox remains enabled, no personal filesystem grant is added, and candidate production entitlements are unchanged. Only the isolated XCTest host enables get-task-allow for test injection.",
      limitations:["The personal check bypasses PlaybackController specifically to prohibit progress writes; its controller/recovery/progress path is tested separately with synthetic fixtures.",
        "The exact candidate packaged server is launched directly; helper/autostart is a separate check.",
        "The signed Release test host is compiled from the verified candidate source with testability enabled; this is not UI automation of the original candidate executable.",
        "The isolated XCTest host has a debugging entitlement for test injection; this does not prove runtime behavior under the untouched candidate distribution entitlements.",
        "This is a bounded output-counter check through6:45, not proof for the complete episode or a human picture/hearing assessment."]}' \
    >"$final_summary"
  [[ $? == 0 ]] || exit_code=1
  evidence_remove_owned_run "$EVIDENCE_RUN_ROOT" || exit_code=1
  print -r -- "Bounded authorized playback summary: $final_summary"
  print -r -- "Bounded authorized playback XCTest evidence: $final_result"
  exit "$exit_code"
}
trap finish EXIT
trap 'exit 130' INT TERM

last_phase='authorized source metadata before playback'
ruby "$repository_root/tools/macos/authorized-playback-source-metadata.rb" before \
  "$EVIDENCE_RUN_ROOT/source-before.private.json"
source_bytes=$(jq -er '.size | select(. > 0)' "$EVIDENCE_RUN_ROOT/source-before.private.json")
last_phase='original candidate signatures'
AURELIA_SIGNING_IDENTITY=$(evidence_signing_identity "$candidate" "$EVIDENCE_RUN_ROOT")
export AURELIA_SIGNING_IDENTITY
/usr/bin/codesign --verify --strict "$server" >"$EVIDENCE_RUN_ROOT/server-signature.private.log" 2>&1
last_phase='owned source-only client snapshot'
source_fingerprint=$(ruby "$repository_root/tools/macos/playback-client-source-fingerprint.rb" "$repository_root")
[[ "$source_fingerprint" == "$AURELIA_CANDIDATE_CLIENT_SOURCE_FINGERPRINT" ]] \
  || { evidence_fail candidate_client_source_changed_since_build_provenance_capture; exit 1; }
ruby "$repository_root/tools/macos/stage-playback-evidence-source.rb" "$repository_root" \
  "$source_root" "$repository_root/tools/macos/PlaybackAuthorizedSourceTests.swift"
[[ "$(ruby "$repository_root/tools/macos/playback-client-source-fingerprint.rb" "$source_root" --owned-snapshot)" == "$source_fingerprint" ]] \
  || { evidence_fail client_snapshot_does_not_match_candidate_source; exit 1; }
source_provenance_verified=true
last_phase='offline current-model provisioner build'
"$DOTNET_BIN" publish "$repository_root/tools/macos/PlaybackEvidenceProvisioner/PlaybackEvidenceProvisioner.csproj" \
  --configuration Release --runtime "$runtime" --self-contained false \
  -p:AureliaBuildRoot="$EVIDENCE_RUN_ROOT/DotnetProvisionerBuild" \
  -p:TreatWarningsAsErrors=true --output "$provisioner_publish" \
  >"$EVIDENCE_RUN_ROOT/provisioner-build.private.log" 2>&1
last_phase='isolated owner setup'
export AURELIA_EVIDENCE_OWNER_PASSWORD="authorized-source-$(uuidgen)-synthetic-only!"
print -r -- "$AURELIA_EVIDENCE_OWNER_PASSWORD" \
  | AURELIA_LAN_ENABLED=false ASPNETCORE_ENVIRONMENT=Production \
    "$server" setup-owner --data-dir "$server_data" --username authorized-source-owner \
      --device-name 'Bounded Authorized Playback Evidence' --password-stdin \
      >"$EVIDENCE_RUN_ROOT/owner-output.private" 2>"$EVIDENCE_RUN_ROOT/setup-errors.private"
tail -n 1 "$EVIDENCE_RUN_ROOT/owner-output.private" >"$EVIDENCE_RUN_ROOT/authentication.private.json"
jq -e '.token and .sessionId and .user.role == "owner"' "$EVIDENCE_RUN_ROOT/authentication.private.json" >/dev/null
last_phase='one exact offline source metadata row'
AURELIA_EVIDENCE_AUTHORIZED_SOURCE_FILE="$AURELIA_AUTHORIZED_MEDIA_FILE" \
  "$DOTNET_BIN" "$provisioner_publish/PlaybackEvidenceProvisioner.dll" authorized-personal \
    "$server_data/aurelia.db" "$EVIDENCE_RUN_ROOT/authorized-source.private.json" \
    >"$EVIDENCE_RUN_ROOT/provisioner-output.private" 2>&1
http_port=$(ruby -rsocket -e 's = TCPServer.new("127.0.0.1", 0); puts s.addr[1]; s.close')
https_port=$(ruby -rsocket -e 's = TCPServer.new("127.0.0.1", 0); puts s.addr[1]; s.close')
[[ "$http_port" != "$https_port" ]] || { evidence_fail isolated_test_ports_collided; exit 1; }
jq -n --argjson port "$https_port" \
  '{version:2,serverName:"Aurelia Authorized Playback Evidence",lanAccessEnabled:true,lanHttpsPort:$port,
    revision:1,bonjourEnabled:false,monitoringEnabled:false,automaticBackupsEnabled:false}' \
  >"$server_data/server-settings.json"
last_phase='owned exact packaged HTTPS server readiness'
AURELIA_HOST_PARENT_PID=$$ ASPNETCORE_ENVIRONMENT=Production \
  AURELIA_SERVER_NAME='Aurelia Authorized Playback Evidence' Logging__LogLevel__Default=Warning \
  "$server" --data-dir "$server_data" --urls "http://127.0.0.1:$http_port" \
    --lan --lan-port "$https_port" >"$EVIDENCE_RUN_ROOT/server-output.private" 2>&1 &
server_pid=$!
for _ in {1..150}; do
  kill -0 "$server_pid" 2>/dev/null || { evidence_fail owned_server_exited_before_readiness; exit 1; }
  if curl --silent --fail --max-time 1 "http://127.0.0.1:$http_port/api/v1/server/info" \
    >"$EVIDENCE_RUN_ROOT/server-info.private.json"; then
    break
  fi
  sleep 0.2
done
jq -e --arg version "$server_version" \
  '.isSetup == true and .version == $version and .name == "Aurelia Authorized Playback Evidence"' \
  "$EVIDENCE_RUN_ROOT/server-info.private.json" >/dev/null
evidence_register_server_pid "$server_pid" "$server" "$server_data"
fingerprint=$(openssl x509 -in "$server_data/server-certificate.pem" -pubkey -noout \
  | openssl pkey -pubin -outform DER | shasum -a 256 | awk '{print toupper($1)}')
[[ ${#fingerprint} == 64 && "$fingerprint" != *[^A-F0-9]* ]] \
  || { evidence_fail missing_owned_server_pin; exit 1; }

last_phase="signed owned $configuration playback-only test host build"
"$repository_root/scripts/prepare-vlckit.sh" >"$EVIDENCE_RUN_ROOT/vlc-preparation.private.log" 2>&1
mkdir -p "$source_root/clients/macos/Dependencies"
ln -s "$repository_root/clients/macos/Dependencies/VLCKit.xcframework" \
  "$source_root/clients/macos/Dependencies/VLCKit.xcframework"
/usr/bin/ditto "$repository_root/clients/macos/Dependencies/VLCKit-COPYING.txt" \
  "$source_root/clients/macos/Dependencies/VLCKit-COPYING.txt"
# Keep the snapshot's automatic signing and verify its actual leaf before
# launch; a concrete certificate override conflicts with automatic signing.
# Enable XCTest injection only for this isolated snapshot's test host. Do not
# alter the original candidate, source entitlements or hardened-runtime setting.
test_build_settings=(ENABLE_TESTABILITY=YES SWIFT_TREAT_WARNINGS_AS_ERRORS=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=YES)
if [[ "$configuration" == Release ]]; then
  # The complete ordinary Debug suite covers these DEBUG-only preview fixtures.
  test_build_settings+=("EXCLUDED_SOURCE_FILE_NAMES=ServerSettingsRenderTests.swift ImportPlanningTests.swift MetadataEditorTests.swift")
fi
DEVELOPER_DIR="$developer_dir" xcodebuild -quiet \
  -project "$source_root/clients/macos/Aurelia.xcodeproj" -scheme Aurelia \
  -configuration "$configuration" -destination "platform=macOS,arch=$architecture" \
  -derivedDataPath "$derived_data" -enableCodeCoverage NO \
  "${test_build_settings[@]}" build-for-testing >"$EVIDENCE_RUN_ROOT/xcodebuild.private.log" 2>&1 &
EVIDENCE_TOOL_PID=$!
wait "$EVIDENCE_TOOL_PID"
EVIDENCE_TOOL_PID=''
test_host="$derived_data/Build/Products/$configuration/Aurelia.app"
evidence_copy_test_vlc "$test_host" "$derived_data/Build/Products/$configuration/VLCKit.framework"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$test_host/Contents/Info.plist")" == "$server_version" ]] \
  || { evidence_fail candidate_and_client_snapshot_version_mismatch; exit 1; }
/usr/bin/codesign --verify --deep --strict "$test_host" >"$EVIDENCE_RUN_ROOT/test-signature.private.log" 2>&1
[[ "$(evidence_signing_identity "$test_host" "$EVIDENCE_RUN_ROOT")" == "$AURELIA_SIGNING_IDENTITY" ]] \
  || { evidence_fail test_host_signing_identity_changed; exit 1; }
/usr/bin/codesign --display --entitlements - --xml "$test_host" \
  >"$EVIDENCE_RUN_ROOT/test-entitlements.private.plist" 2>>"$EVIDENCE_RUN_ROOT/test-signature.private.log"
/usr/bin/plutil -convert json -o "$EVIDENCE_RUN_ROOT/test-entitlements.private.json" \
  "$EVIDENCE_RUN_ROOT/test-entitlements.private.plist"
jq -e '.["com.apple.security.app-sandbox"] == true
  and .["com.apple.security.network.client"] == true
  and .["com.apple.security.network.server"] == true
  and .["com.apple.security.temporary-exception.files.absolute-path.read-only"] == null
  and .["com.apple.security.temporary-exception.files.absolute-path.read-write"] == null' \
  "$EVIDENCE_RUN_ROOT/test-entitlements.private.json" >/dev/null \
  || { evidence_fail actual_signed_sandbox_or_no_personal_grant_assertion; exit 1; }
signed_sandbox_verified=true
evidence_require_test_debugger_allowance "$test_host"
test_debugger_allowance_verified=true
# No filesystem grant is needed: the app sees only HTTP and never opens the
# original path. The signed server uses unchanged production read-only access.
export TEST_RUNNER_AURELIA_UI_TEST_MODE=playback-evidence
export TEST_RUNNER_AURELIA_PREFLIGHT_TEST=1
export TEST_RUNNER_AURELIA_DATA_DIR="$server_data"
export TEST_RUNNER_AURELIA_SOURCE_EVIDENCE_OWNED_STATE=YES
export TEST_RUNNER_AURELIA_SOURCE_EVIDENCE_AUTHORIZATION="$AURELIA_AUTHORIZED_PLAYBACK"
export TEST_RUNNER_AURELIA_SOURCE_EVIDENCE_SERVER_URL="https://127.0.0.1:$https_port"
export TEST_RUNNER_AURELIA_SOURCE_EVIDENCE_FINGERPRINT="$fingerprint"
export TEST_RUNNER_AURELIA_SOURCE_EVIDENCE_AUTH="$(<"$EVIDENCE_RUN_ROOT/authentication.private.json")"
export TEST_RUNNER_AURELIA_SOURCE_EVIDENCE_SERVER_VERSION="$server_version"
export TEST_RUNNER_AURELIA_SOURCE_EVIDENCE_SOURCE_BYTES="$source_bytes"
export TEST_RUNNER_AURELIA_SOURCE_EVIDENCE_MEDIA_ID=94efcf84-939f-47a8-9d7c-6e0f494c2710
# Prevent source paths/approval markers from being inherited by the test host
# or echoed in XCTest launch environments. Its configuration contains only an
# opaque owned media ID, numeric size and private test authentication.
export AURELIA_EVIDENCE_AUTHORIZED_SOURCE_FILE="$AURELIA_AUTHORIZED_MEDIA_FILE"
last_phase='independent bounded-read watchdog validation'
ruby "$repository_root/scripts/playback-authorized-read-watchdog.rb" "$server_pid" \
  "$server" "$server_data" "$EVIDENCE_RUN_ROOT" "$EVIDENCE_RUN_ROOT/source-read-deadline.private" \
  >"$EVIDENCE_RUN_ROOT/watchdog-output.private.log" 2>&1 &
EVIDENCE_WATCHDOG_PID=$!
for _ in {1..50}; do
  kill -0 "$EVIDENCE_WATCHDOG_PID" 2>/dev/null \
    || { evidence_fail authorized_source_watchdog_failed_to_start; exit 1; }
  [[ ! -f "$EVIDENCE_RUN_ROOT/source-read-watchdog-ready.private" ]] || break
  sleep 0.1
done
[[ -f "$EVIDENCE_RUN_ROOT/source-read-watchdog-ready.private" ]] \
  || { evidence_fail authorized_source_watchdog_readiness_timed_out; exit 1; }
last_phase='bounded actual authorized-source playback from0 through7m10s'
test_attempted=true
set +e
/usr/bin/env -u AURELIA_AUTHORIZED_MEDIA_FILE -u AURELIA_EVIDENCE_AUTHORIZED_SOURCE_FILE \
  -u AURELIA_AUTHORIZED_PLAYBACK DEVELOPER_DIR="$developer_dir" xcodebuild -quiet \
  -project "$source_root/clients/macos/Aurelia.xcodeproj" -scheme Aurelia \
  -configuration "$configuration" -destination "platform=macOS,arch=$architecture" \
  -derivedDataPath "$derived_data" -resultBundlePath "$result" \
  -enableCodeCoverage NO -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 600 \
  -only-testing:AureliaTests/PlaybackAuthorizedSourceTests \
  "${test_build_settings[@]}" test-without-building >>"$EVIDENCE_RUN_ROOT/xcodebuild.private.log" 2>&1 &
EVIDENCE_TOOL_PID=$!
wait "$EVIDENCE_TOOL_PID"
test_exit_code=$?
EVIDENCE_TOOL_PID=''
set -e
if [[ -d "$result" ]] \
  && DEVELOPER_DIR="$developer_dir" xcrun xcresulttool get test-results summary \
    --path "$result" >"$EVIDENCE_RUN_ROOT/test-summary.private.json" \
    2>"$EVIDENCE_RUN_ROOT/test-summary-errors.private.log" \
  && jq -e '(.totalTestCount // 0) == 1 and (.skippedTests // 0) == 0
    and (((.passedTests // 0) + (.failedTests // 0)) == 1)' \
    "$EVIDENCE_RUN_ROOT/test-summary.private.json" >/dev/null; then
  test_executed=true
else
  last_phase='XCTest launch or completed-test evidence'
  evidence_fail mandatory_authorized_source_test_did_not_complete
  exit 1
fi
[[ "$test_exit_code" == 0 ]] || exit "$test_exit_code"
last_phase='complete'
