#!/bin/zsh
set -euo pipefail
umask 077

# Optional playback diagnostic, run only at the user's explicit request.
# Uses only generated test media and a private
# database/account; never launches/stops the installed app or reads its library.
# Usage: zsh scripts/test-playback-full-chain.sh /path/to/staged/Aurelia.app [soak-seconds]
# Capture AURELIA_CANDIDATE_CLIENT_SOURCE_FINGERPRINT before building the
# candidate; an all-format >=1800-second diagnostic requires that provenance.
# Optional AURELIA_FULL_CHAIN_FORMAT_FILTER=AVI|MP4|MKV is diagnostic only;
# the default all-format run checks the complete optional diagnostic criteria.
repository_root=${0:A:h:h}
source "$repository_root/scripts/workspace-paths.sh"
source "$repository_root/scripts/playback-evidence-common.sh"
candidate=${1:-}
soak_seconds=${2:-180}
[[ -d "$candidate/Contents" ]] || { print -u2 'Supply a verified staged Aurelia.app.'; exit 2; }
[[ "$soak_seconds" == <120-7200> ]] || { print -u2 'Soak duration must be 120–7200 seconds (1800 for 30 minutes). Each other format plays for at least 120 seconds.'; exit 2; }
candidate=${candidate:A}
configuration=${AURELIA_FULL_CHAIN_CONFIGURATION:-Release}
format_filter=${AURELIA_FULL_CHAIN_FORMAT_FILTER:-}
[[ -z "$format_filter" || "$format_filter" == AVI || "$format_filter" == MP4 || "$format_filter" == MKV ]] \
  || { print -u2 'The optional diagnostic format filter must be AVI, MP4 or MKV.'; exit 2; }
test_filter=${AURELIA_FULL_CHAIN_TEST_FILTER:-AureliaTests/PlaybackFullChainTests/testPackagedPinnedServerRelayAndRealVideoAudio}
required_method_selected=false
required_method_verified=false
case "$test_filter" in
  AureliaTests|AureliaTests/PlaybackFullChainTests|AureliaTests/PlaybackFullChainTests/testPackagedPinnedServerRelayAndRealVideoAudio)
    required_method_selected=true ;;
esac
if [[ "$test_filter" == AureliaTests/PlaybackFullChainTests ]]; then
  test_filter=AureliaTests/PlaybackFullChainTests/testPackagedPinnedServerRelayAndRealVideoAudio
fi
expected_client_source_fingerprint=${AURELIA_CANDIDATE_CLIENT_SOURCE_FINGERPRINT:-}
source_provenance_required=false
source_provenance_supplied=false
if (( soak_seconds >= 1800 )) && [[ -z "$format_filter" && "$required_method_selected" == true ]]; then
  source_provenance_required=true
fi
if [[ -n "$expected_client_source_fingerprint" ]]; then
  [[ ${#expected_client_source_fingerprint} == 64 \
    && "$expected_client_source_fingerprint" != *[^A-F0-9]* ]] \
    || { evidence_fail invalid_candidate_client_source_fingerprint; exit 2; }
  source_provenance_supplied=true
elif [[ "$source_provenance_required" == true ]]; then
  evidence_fail mandatory_gate_requires_fingerprint_captured_before_candidate_build
  exit 2
fi
[[ "$configuration" == Release || "$configuration" == Debug ]] \
  || { print -u2 'Full chain configuration must be Release or Debug.'; exit 2; }
runtime='osx-arm64'
[[ "$(uname -m)" == x86_64 ]] && runtime='osx-x64'
server="$candidate/Contents/Resources/Server/$runtime/Aurelia.Server"
[[ -x "$server" ]] || { print -u2 'The staged app has no packaged server for this architecture.'; exit 2; }
runtime_parent="$HOME/Library/Caches/Aurelia/TestRuns"
mkdir -p "$runtime_parent" "$other_root/Test Results" "$other_root/Logs"
runtime_root=$(mktemp -d "$runtime_parent/full-chain-XXXXXXXX")
EVIDENCE_RUN_ROOT=$runtime_root
EVIDENCE_PROJECT_PATH="$repository_root/clients/macos/Aurelia.xcodeproj"
EVIDENCE_FORCED_SHUTDOWN=false
export EVIDENCE_RUN_ROOT
run_id=${runtime_root:t}
data_root="$runtime_root/ServerData"
derived_data="$runtime_root/DerivedData"
result="$runtime_root/Playback-Full-Chain.xcresult"
ordinary_result="$runtime_root/Playback-Ordinary-Unit.xcresult"
final_result="$other_root/Test Results/Aurelia-Playback-Full-Chain-$run_id.xcresult"
final_ordinary_result="$other_root/Test Results/Aurelia-Playback-Ordinary-Unit-$run_id.xcresult"
final_log="$other_root/Logs/Aurelia-Playback-Full-Chain-$run_id.log"
final_summary="$other_root/Test Results/Aurelia-Playback-Full-Chain-$run_id.json"
mkdir -p "$data_root"
media_root="$runtime_root/Fixtures"
mkdir -p "$media_root"
server_pid=''
fixture_grant_verified=false
test_debugger_allowance_verified=false
test_host_version_build_verified=false
client_source_before_build_verified=false
client_source_before_launch_verified=false
client_source_after_run_verified=false
last_phase='configuration'
owner_password="full-chain-$(uuidgen)-synthetic-only!"
export AURELIA_EVIDENCE_OWNER_PASSWORD="$owner_password"
server_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$candidate/Contents/Info.plist")
build_number=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$candidate/Contents/Info.plist")
http_port=$(ruby -rsocket -e 's = TCPServer.new("127.0.0.1", 0); puts s.addr[1]; s.close')
https_port=$(ruby -rsocket -e 's = TCPServer.new("127.0.0.1", 0); puts s.addr[1]; s.close')
[[ "$http_port" != "$https_port" ]] || { print -u2 'The isolated test ports collided. Retry the run.'; exit 2; }

fail_fixture_grant() {
  # Fixed step identifiers are safe to retain; raw signing output stays private.
  last_phase="test-only shared fixture grant: $1"
  print -u2 -r -- "Full chain fixture grant failed: $1"
  exit 1
}

verify_client_source() {
  local phase=${1:-} actual
  [[ "$source_provenance_supplied" == true ]] || return 0
  actual=$(ruby "$repository_root/tools/macos/playback-client-source-fingerprint.rb" "$repository_root") \
    || { evidence_fail candidate_client_source_fingerprint_unavailable; return 1; }
  [[ "$actual" == "$expected_client_source_fingerprint" ]] \
    || { evidence_fail candidate_client_source_changed_since_build_capture; return 1; }
  case "$phase" in
    before_build) client_source_before_build_verified=true ;;
    before_launch) client_source_before_launch_verified=true ;;
    after_run) client_source_after_run_verified=true ;;
    *) evidence_fail invalid_client_source_verification_phase; return 1 ;;
  esac
}

finish() {
  local exit_code=$? cleanup_failed=false client_source_provenance_verified=false
  set +e
  verify_client_source after_run || exit_code=1
  if [[ "$client_source_before_build_verified" == true \
    && "$client_source_before_launch_verified" == true \
    && "$client_source_after_run_verified" == true ]]; then
    client_source_provenance_verified=true
  fi
  evidence_stop_owned_build_tools || cleanup_failed=true
  evidence_stop_test_hosts || cleanup_failed=true
  if [[ -n "$server_pid" ]]; then
    evidence_stop_pid "$server_pid" || cleanup_failed=true
  fi
  [[ ! -d "$result" ]] || /usr/bin/ditto "$result" "$final_result" || cleanup_failed=true
  [[ ! -d "$ordinary_result" ]] || /usr/bin/ditto "$ordinary_result" "$final_ordinary_result" || cleanup_failed=true
  [[ ! -f "$runtime_root/xcodebuild.log" ]] || evidence_export_log "$runtime_root/xcodebuild.log" \
    "$final_log" "$runtime_root/authentication.private.json" || cleanup_failed=true
  # Do not remove this run while an owned test host, build tool or supervisor
  # still uses it. Cleanup failure is a failed gate, never a successful report.
  evidence_remove_owned_run "$runtime_root" || cleanup_failed=true
  [[ "$cleanup_failed" == false ]] || exit_code=1
  jq -n --arg phase "$last_phase" --arg version "$server_version" --arg build "$build_number" \
    --arg architecture "$runtime" --arg configuration "$configuration" \
    --arg formatFilter "$format_filter" \
    --arg testFilter "$test_filter" --argjson requiredMethodSelected "$required_method_selected" \
    --argjson requiredMethodVerified "$required_method_verified" \
    --argjson code "$exit_code" --argjson forcedShutdown "$EVIDENCE_FORCED_SHUTDOWN" \
    --argjson cleanupFailed "$cleanup_failed" \
    --argjson fixtureGrantVerified "$fixture_grant_verified" \
    --argjson testDebuggerAllowanceVerified "$test_debugger_allowance_verified" \
    --argjson testHostVersionBuildVerified "$test_host_version_build_verified" \
    --argjson sourceProvenanceRequired "$source_provenance_required" \
    --argjson clientSourceProvenanceVerified "$client_source_provenance_verified" \
    --argjson clientSourceBeforeBuildVerified "$client_source_before_build_verified" \
    --argjson clientSourceBeforeLaunchVerified "$client_source_before_launch_verified" \
    --argjson clientSourceAfterRunVerified "$client_source_after_run_verified" \
    --argjson requestedSoakSeconds "$soak_seconds" \
    '{formatVersion:4,passed:($code==0 and $formatFilter=="" and $requiredMethodVerified
        and $requestedSoakSeconds>=1800 and $clientSourceProvenanceVerified
        and $configuration=="Release"),
      allFormatSuiteSucceeded:($code==0 and $formatFilter=="" and $requiredMethodVerified),
      diagnosticSubsetSucceeded:($code==0 and ($formatFilter!="" or ($requiredMethodSelected|not)
        or $requestedSoakSeconds<1800 or $configuration!="Release")),
      requiredFullGateComplete:($code==0 and $formatFilter=="" and $requiredMethodVerified
        and $requestedSoakSeconds>=1800 and $clientSourceProvenanceVerified
        and $configuration=="Release"),
      formatFilter:(if $formatFilter=="" then "all" else $formatFilter end),
      requestedTestFilter:$testFilter,requiredMethodSelected:$requiredMethodSelected,
      requiredMethodCompletedWithoutSkipping:$requiredMethodVerified,
      exitCode:$code,phase:$phase,version:$version,build:$build,
      architecture:$architecture,clientConfiguration:$configuration,
      requestedSoakSeconds:$requestedSoakSeconds,forcedShutdown:$forcedShutdown,
      cleanupFailed:$cleanupFailed,
      requiredMinimumBaselineSecondsPerFormat:120,
      requiredTestHostSandboxEnabled:true,testHostFixtureGrantVerified:$fixtureGrantVerified,
      testHostDebuggerAllowanceVerified:$testDebuggerAllowanceVerified,
      actualTestHostVersionAndBuildMatchCandidate:$testHostVersionBuildVerified,
      candidateClientSourceProvenanceRequired:$sourceProvenanceRequired,
      candidateClientCodeAndCompilerConfigurationProvenanceVerified:$clientSourceProvenanceVerified,
      clientSourceBeforeTestBuildVerified:$clientSourceBeforeBuildVerified,
      clientSourceBeforeTestLaunchVerified:$clientSourceBeforeLaunchVerified,
      clientSourceAfterRunVerified:$clientSourceAfterRunVerified,
      requiredSavedProfileAndNativeHostStartupRejected:true,
      testHostFixtureGrant:"A test-only read/write exception for this run\u0027s exact canonical generated-fixture directory simulates user-selected folder access. All original entitlements and the original signing identity are retained; production entitlements are unchanged.",
      requiredInterruptions:["Owned server stop/restart preserves TLS pin and ends volatile viewing sessions; fresh PIN unlock resumes unfinished progress",
        "Persistent owned server outage reaches bounded terminal state, then explicit PIN unlock resumes",
        "Generated source folder offline returns typed 503, then restore and automatic resume"],
      requiredEpisodeContinuity:"The all-format gate provisions two numbered generated-source episodes through the production API, resumes actual unfinished server progress, observes natural VLC EOF and automatic second-episode video/audio, and requires completed progress for the previous episode.",
      methodology:"Signed test host with production API, exact packaged server in isolated Testing environment, pinned HTTPS, real loopback relay, default VLC video/audio outputs and generated AVI/MP4/MKV only.",
      evidence:"Detailed redacted HTTP/output samples are attached to the XCTest result bundle.",
      limitations:["Human hearing and image quality are not automatically verified.",
        "The isolated XCTest host enables get-task-allow for test injection and has an exact generated-fixture grant. This is not execution of the untouched candidate with its distribution entitlements; candidate signing/runtime is checked separately.",
        "A single-format diagnostic run cannot certify the mandatory all-format gate.",
        "An all-format run shorter than 1800s is diagnostic only, even when all cases succeed.",
        "A Debug test-host run is diagnostic only, even with all formats and a 1800s soak.",
        "Client provenance compares the code/configuration fingerprint supplied from before candidate build at test build, test launch and completion; it is not a binary identity check against the candidate executable.",
        "Short tickets are enabled only in the isolated Testing server; production keeps its 12-hour lifetime.",
        "The packaged server is started directly for this playback gate; helper/autostart is a separate smoke."]}' \
    >"$final_summary"
  [[ $? == 0 ]] || exit_code=1
  print -r -- "Full chain result: $final_summary"
  print -r -- "Full chain XCTest evidence: $final_result"
  exit "$exit_code"
}
trap finish EXIT
trap 'exit 130' INT TERM

last_phase='signature verification'
/usr/bin/codesign --verify --deep --strict "$candidate"
/usr/bin/codesign --verify --strict "$server"

last_phase='isolated owner setup'
print -r -- "$owner_password" | \
  AURELIA_LAN_ENABLED=false ASPNETCORE_ENVIRONMENT=Testing \
  "$server" setup-owner --data-dir "$data_root" --username full-chain-owner \
    --device-name 'Full Chain Release Test' --password-stdin \
    >"$runtime_root/owner-output.private" 2>"$runtime_root/setup-errors.private"
tail -n 1 "$runtime_root/owner-output.private" >"$runtime_root/authentication.private.json"
jq -e '.token and .sessionId and .user.role == "owner"' "$runtime_root/authentication.private.json" >/dev/null

# Explicitly disable discovery, monitoring and scheduled backups in owned test
# state. The short-ticket seam is honored only when the server environment is Testing.
jq -n --argjson port "$https_port" \
  '{version:2,serverName:"Aurelia Full Chain Test",lanAccessEnabled:true,lanHttpsPort:$port,
    revision:1,bonjourEnabled:false,monitoringEnabled:false,automaticBackupsEnabled:false}' \
  >"$data_root/server-settings.json"
last_phase='packaged HTTPS server startup'
ruby "$repository_root/scripts/full-chain-server-control.rb" \
  "$server" "$data_root" "$http_port" "$https_port" \
  "$runtime_root/server-control.private.json" "$runtime_root/server-output.private" "$$" \
  >"$runtime_root/control-output.private" 2>&1 &
server_pid=$!
EVIDENCE_CONTROL_PID=$server_pid
EVIDENCE_SERVER_EXECUTABLE=$server
EVIDENCE_SERVER_DATA_ROOT=$data_root
for _ in {1..150}; do
  kill -0 "$server_pid" 2>/dev/null || { print -u2 'The isolated packaged server exited before readiness.'; exit 1; }
  if curl --silent --fail --max-time 1 "http://127.0.0.1:$http_port/api/v1/server/info" \
    >"$runtime_root/server-info.private.json"; then
    break
  fi
  sleep 0.2
done
jq -e --arg version "$server_version" '.isSetup == true and .version == $version' \
  "$runtime_root/server-info.private.json" >/dev/null
fingerprint=$(openssl x509 -in "$data_root/server-certificate.pem" -pubkey -noout \
  | openssl pkey -pubin -outform DER | shasum -a 256 | awk '{print toupper($1)}')
[[ ${#fingerprint} == 64 ]] || { print -u2 'The owned server certificate fingerprint is unavailable.'; exit 1; }
control_url=$(jq -er '.controlURL' "$runtime_root/server-control.private.json")

last_phase="signed $configuration test host build"
verify_client_source before_build
"$repository_root/scripts/prepare-vlckit.sh"
# Permit XCTest injection only in this isolated test build. The production
# candidate/project keeps its Release entitlement and hardened-runtime settings.
test_build_settings=(ENABLE_TESTABILITY=YES SWIFT_TREAT_WARNINGS_AS_ERRORS=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=YES ONLY_ACTIVE_ARCH=YES)
if [[ "$configuration" == Release ]]; then
  # These unrelated UI/editor fixtures call a DEBUG-only preview symbol. The
  # complete ordinary suite is verified separately under Debug.
  test_build_settings+=("EXCLUDED_SOURCE_FILE_NAMES=ServerSettingsRenderTests.swift ImportPlanningTests.swift MetadataEditorTests.swift")
fi
DEVELOPER_DIR="$developer_dir" xcodebuild -quiet \
  -project "$repository_root/clients/macos/Aurelia.xcodeproj" -scheme Aurelia \
  -configuration "$configuration" -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$derived_data" -enableCodeCoverage NO \
  "${test_build_settings[@]}" \
  build-for-testing 2>&1 | tee "$runtime_root/xcodebuild.log"
embedded_vlc="$derived_data/Build/Products/$configuration/Aurelia.app/Contents/Frameworks/VLCKit.framework"
test_vlc="$derived_data/Build/Products/$configuration/VLCKit.framework"
[[ -d "$embedded_vlc" && -d "$test_vlc" && ! -L "$test_vlc" ]] \
  || { print -u2 'The isolated signed VLC test framework copies are unavailable.'; exit 1; }
/usr/bin/codesign --verify --strict "$embedded_vlc"
/usr/bin/ditto "$embedded_vlc" "$test_vlc"
/usr/bin/codesign --verify --strict "$test_vlc"
test_host="$derived_data/Build/Products/$configuration/Aurelia.app"
/usr/bin/codesign --verify --strict "$test_host"

last_phase='test-only shared fixture folder grant'
# The normal app obtains media-folder access through the user's file picker.
# The isolated test host instead receives one exact run-owned fixture grant;
# the production entitlement source and the staged candidate are never changed.
[[ "$media_root" == "$runtime_root/Fixtures" && -d "$media_root" && ! -L "$media_root" ]] \
  || { print -u2 'The owned fixture grant target is invalid.'; exit 1; }
original_entitlements="$runtime_root/test-host-original-entitlements.private.plist"
test_entitlements="$runtime_root/test-host-entitlements.private.plist"
verified_entitlements="$runtime_root/test-host-verified-entitlements.private.plist"
grant_key='com.apple.security.temporary-exception.files.absolute-path.read-write'
/usr/bin/codesign --display --entitlements - --xml "$test_host" \
  >"$original_entitlements" 2>"$runtime_root/test-signing.private.log" \
  || fail_fixture_grant extract_original_entitlements
/usr/bin/plutil -lint "$original_entitlements" >/dev/null \
  || fail_fixture_grant validate_original_entitlement_plist
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$original_entitlements")" == true ]] \
  || { print -u2 'The original signed test host does not have its sandbox enabled.'; exit 1; }
if /usr/libexec/PlistBuddy -c "Print :$grant_key" "$original_entitlements" >/dev/null 2>&1; then
  print -u2 'The original host already has a filesystem exception; refusing to expand it.'
  exit 1
fi
/usr/bin/ditto "$original_entitlements" "$test_entitlements" \
  || fail_fixture_grant copy_original_entitlements
/usr/libexec/PlistBuddy -c "Add :${grant_key} array" "$test_entitlements" \
  || fail_fixture_grant add_exact_fixture_grant_array
/usr/libexec/PlistBuddy -c "Add :${grant_key}:0 string $media_root/" "$test_entitlements" \
  || fail_fixture_grant add_exact_fixture_grant_path
/usr/bin/plutil -convert json -o "$runtime_root/test-original-entitlements.private.json" "$original_entitlements" \
  || fail_fixture_grant convert_original_entitlements
/usr/bin/plutil -convert json -o "$runtime_root/test-entitlements.private.json" "$test_entitlements" \
  || fail_fixture_grant convert_test_entitlements
jq -e --slurp --arg key "$grant_key" --arg path "$media_root/" \
  '.[0] as $original | .[1] as $test |
   ($original["com.apple.security.app-sandbox"] == true) and
   (($test | del(.[$key])) == $original) and ($test[$key] == [$path])' \
  "$runtime_root/test-original-entitlements.private.json" "$runtime_root/test-entitlements.private.json" >/dev/null \
  || fail_fixture_grant verify_only_exact_fixture_grant_added
# Resolve the leaf certificate actually used by this host, rather than choosing
# an arbitrary identity from Keychain or embedding a machine-specific identity.
/usr/bin/codesign --display --extract-certificates="$runtime_root/test-host-original-certificate-" \
  "$test_host" 2>>"$runtime_root/test-signing.private.log" \
  || fail_fixture_grant extract_original_signing_certificate
host_signing_identity=$(openssl x509 -inform DER \
  -in "$runtime_root/test-host-original-certificate-0" -noout -fingerprint -sha1 \
  | awk -F= '{ gsub(":", "", $2); print toupper($2) }') \
  || fail_fixture_grant calculate_original_certificate_fingerprint
signing_identity=${AURELIA_SIGNING_IDENTITY:-$host_signing_identity}
[[ ${#host_signing_identity} == 40 && "$signing_identity" == "$host_signing_identity" ]] \
  || { print -u2 'The test fixture grant must use the original host signing identity.'; exit 1; }
/usr/bin/security find-identity -v -p codesigning \
  | awk -v identity="$signing_identity" '$2 == identity { found=1 } END { exit !found }' \
  || { print -u2 'The original host signing identity is not available.'; exit 1; }
# Re-sign only the outer isolated host; never deep-sign its helper/frameworks.
/usr/bin/codesign --force --sign "$signing_identity" --timestamp=none \
  --preserve-metadata=identifier,requirements,flags,runtime,launch-constraints,library-constraints \
  --entitlements "$test_entitlements" "$test_host" 2>>"$runtime_root/test-signing.private.log" \
  || fail_fixture_grant resign_isolated_test_host
/usr/bin/codesign --verify --deep --strict "$test_host" \
  || fail_fixture_grant verify_isolated_test_host_signature
/usr/bin/codesign --display --entitlements - --xml "$test_host" \
  >"$verified_entitlements" 2>>"$runtime_root/test-signing.private.log" \
  || fail_fixture_grant extract_verified_entitlements
/usr/bin/plutil -convert json -o "$runtime_root/test-verified-entitlements.private.json" "$verified_entitlements" \
  || fail_fixture_grant convert_verified_entitlements
jq -e --slurp '.[0] == .[1]' "$runtime_root/test-entitlements.private.json" \
  "$runtime_root/test-verified-entitlements.private.json" >/dev/null \
  || fail_fixture_grant compare_actual_signed_entitlements
/usr/bin/codesign --display --extract-certificates="$runtime_root/test-host-verified-certificate-" \
  "$test_host" 2>>"$runtime_root/test-signing.private.log" \
  || fail_fixture_grant extract_verified_signing_certificate
verified_signing_identity=$(openssl x509 -inform DER \
  -in "$runtime_root/test-host-verified-certificate-0" -noout -fingerprint -sha1 \
  | awk -F= '{ gsub(":", "", $2); print toupper($2) }') \
  || fail_fixture_grant calculate_verified_certificate_fingerprint
[[ "$verified_signing_identity" == "$host_signing_identity" ]] \
  || { print -u2 'The isolated test host signing identity changed unexpectedly.'; exit 1; }
fixture_grant_verified=true
evidence_require_test_debugger_allowance "$test_host"
test_debugger_allowance_verified=true

last_phase='real playback XCTest gate'
# The general Debug unit suite deliberately constructs injected AppModels and
# must retain its normal XCTest-only in-memory behavior. A process-wide native
# preflight flag would reject those explicit synthetic model calls. Run it in a
# separate host, then enable the stronger fail-closed flag only for playback.
if [[ "$test_filter" == AureliaTests ]]; then
  [[ "$configuration" == Debug ]] \
    || { print -u2 'The complete ordinary unit suite requires Debug; use the mandatory full-chain filter for Release.'; exit 2; }
  last_phase='ordinary isolated Debug XCTest suite'
  /usr/bin/env -u TEST_RUNNER_AURELIA_PREFLIGHT_TEST -u TEST_RUNNER_AURELIA_DATA_DIR \
    -u AURELIA_PREFLIGHT_TEST -u AURELIA_DATA_DIR \
    TEST_RUNNER_AURELIA_RUNNING_TESTS=1 DEVELOPER_DIR="$developer_dir" xcodebuild -quiet \
    -project "$repository_root/clients/macos/Aurelia.xcodeproj" -scheme Aurelia \
    -configuration Debug -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath "$derived_data" -resultBundlePath "$ordinary_result" \
    -enableCodeCoverage NO -parallel-testing-enabled NO \
    -only-testing:AureliaTests -skip-testing:AureliaTests/PlaybackFullChainTests \
    "${test_build_settings[@]}" test-without-building 2>&1 | tee -a "$runtime_root/xcodebuild.log"
  evidence_stop_test_hosts
  test_filter=AureliaTests/PlaybackFullChainTests/testPackagedPinnedServerRelayAndRealVideoAudio
  last_phase='real playback XCTest gate'
fi
# Request isolation before Release AppModel initialization. TestRuns is not a
# native-helper preflight location, so AppModel.start must reject this launch
# before saved profiles/settings are read. The XCTest owns its real API path.
export TEST_RUNNER_AURELIA_PREFLIGHT_TEST=1
export TEST_RUNNER_AURELIA_DATA_DIR="$data_root"
export TEST_RUNNER_AURELIA_FULL_CHAIN_SERVER_URL="https://127.0.0.1:$https_port"
export TEST_RUNNER_AURELIA_FULL_CHAIN_FINGERPRINT="$fingerprint"
export TEST_RUNNER_AURELIA_FULL_CHAIN_OWNER_AUTH="$(<"$runtime_root/authentication.private.json")"
export TEST_RUNNER_AURELIA_FULL_CHAIN_PASSWORD="$owner_password"
export TEST_RUNNER_AURELIA_FULL_CHAIN_SERVER_VERSION="$server_version"
export TEST_RUNNER_AURELIA_FULL_CHAIN_SOAK_SECONDS="$soak_seconds"
export TEST_RUNNER_AURELIA_FULL_CHAIN_PAUSE_SECONDS=35
export TEST_RUNNER_AURELIA_FULL_CHAIN_CONTROL_URL="$control_url"
export TEST_RUNNER_AURELIA_FULL_CHAIN_MEDIA_ROOT="$media_root"
if [[ -n "$format_filter" ]]; then
  export TEST_RUNNER_AURELIA_FULL_CHAIN_FORMAT_FILTER="$format_filter"
else
  unset TEST_RUNNER_AURELIA_FULL_CHAIN_FORMAT_FILTER
fi
verify_client_source before_launch
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$test_host/Contents/Info.plist")" == "$server_version" \
  && "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$test_host/Contents/Info.plist")" == "$build_number" ]] \
  || { evidence_fail actual_test_host_version_or_build_differs_from_candidate; exit 1; }
test_host_version_build_verified=true
DEVELOPER_DIR="$developer_dir" xcodebuild -quiet \
  -project "$repository_root/clients/macos/Aurelia.xcodeproj" -scheme Aurelia \
  -configuration "$configuration" -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$derived_data" -resultBundlePath "$result" \
  -enableCodeCoverage NO -parallel-testing-enabled NO \
  -only-testing:"$test_filter" \
  "${test_build_settings[@]}" \
  test-without-building 2>&1 | tee -a "$runtime_root/xcodebuild.log"
if [[ "$required_method_selected" == true ]]; then
  last_phase='mandatory XCTest completion verification'
  xcrun xcresulttool get test-results tests --path "$result" --compact \
    >"$runtime_root/test-tree.private.json" \
    || { print -u2 'The mandatory playback test result is unavailable.'; exit 1; }
  jq -e '[.. | objects | select(.nodeType? == "Test Case") |
    select(.nodeIdentifier? == "PlaybackFullChainTests/testPackagedPinnedServerRelayAndRealVideoAudio()")]
    | length == 1 and all(.[]; .result == "Passed" and .durationInSeconds > 0)' \
    "$runtime_root/test-tree.private.json" >/dev/null \
    || { print -u2 'The mandatory playback XCTest did not complete successfully without skipping.'; exit 1; }
  required_method_verified=true
fi
last_phase='complete'
