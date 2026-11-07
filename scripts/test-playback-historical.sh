#!/bin/zsh
set -euo pipefail
umask 077

# Historical synthetic evidence, never a release/install/rollback workflow.
# Usage: zsh scripts/test-playback-historical.sh /path/to/signed/current/Aurelia.app [120]
# Each exact archived client runs sequentially against its matching archived
# server and an independent owned database, using the same generated fixtures.
repository_root=${0:A:h:h}
script_path=${0:A}
source "$repository_root/scripts/workspace-paths.sh"
source "$repository_root/scripts/playback-evidence-common.sh"
reference_140=793715aa6fd979551eecf2db913fbb0f830d75d1
reference_141=9bdbbaaa867f433f8af5fefc0278a352af305b84
architecture=$(uname -m)
runtime='osx-arm64'
[[ "$(uname -m)" == x86_64 ]] && runtime='osx-x64'
[[ "$architecture" == arm64 || "$architecture" == x86_64 ]] || { evidence_fail unsupported_local_architecture; exit 2; }

# Each version uses a new shell, so set -e failures are captured independently
# and cannot suppress the other requested historical comparison.
if [[ "${1:-}" == --run-version ]]; then
  [[ $# == 5 ]] || { evidence_fail invalid_internal_version_arguments; exit 2; }
  EVIDENCE_RUN_ROOT=$2
  reference=$3
  expected_version=$4
  minimum_seconds=$5
  evidence_assert_owned_run "$EVIDENCE_RUN_ROOT"
  [[ "$minimum_seconds" == <120-600> \
    && (( "$expected_version" == 1.4.0 && "$reference" == "$reference_140" ) \
      || ( "$expected_version" == 1.4.1 && "$reference" == "$reference_141" )) \
    && -f "$EVIDENCE_RUN_ROOT/fixtures.private.json" \
    && -f "$EVIDENCE_RUN_ROOT/fixtures-before.private.json" \
    && -n "${AURELIA_SIGNING_IDENTITY:-}" \
    && "${AURELIA_SIGNING_IDENTITY:-}" != *[^A-F0-9]* \
    && ${#AURELIA_SIGNING_IDENTITY} == 40 ]] \
    || { evidence_fail invalid_owned_version_configuration; exit 2; }
  run_id=${EVIDENCE_RUN_ROOT:t}
  version_root="$EVIDENCE_RUN_ROOT/$expected_version"
  source_root="$version_root/Source"
  server_publish="$version_root/PublishedServer"
  provisioner_publish="$version_root/Provisioner"
  server_data="$version_root/ServerData"
  client_state="$version_root/ClientState"
  derived_data="$version_root/DerivedData"
  result="$version_root/Playback-Historical-$expected_version.xcresult"
  result_prefix="Aurelia-Playback-Historical-$expected_version-$run_id"
  final_result="$other_root/Test Results/$result_prefix.xcresult"
  final_summary="$other_root/Test Results/$result_prefix.json"
  server_pid=''
  EVIDENCE_TOOL_PID=''
  last_phase='archive'
  version_status='setup_failed'
  test_attempted=false
  test_executed=false
  test_exit_code=null
  folder_grant_verified=false
  test_debugger_allowance_verified=false
  fixture_metadata_unchanged=false
  EVIDENCE_FORCED_SHUTDOWN=false
  export EVIDENCE_RUN_ROOT
  mkdir -p "$version_root" "$source_root" "$server_data" "$client_state"

  finish_version() {
    local exit_code=$? cleanup_failed=false log_name
    set +e
    if [[ -n "$EVIDENCE_TOOL_PID" ]]; then
      evidence_stop_pid "$EVIDENCE_TOOL_PID" || cleanup_failed=true
    fi
    evidence_stop_test_hosts || cleanup_failed=true
    if [[ -n "$server_pid" ]]; then
      evidence_stop_packaged_server "$server_pid" "$server" "$server_data" \
        "$EVIDENCE_RUN_ROOT" || cleanup_failed=true
    fi
    evidence_fixture_snapshot "$EVIDENCE_RUN_ROOT/fixtures.private.json" \
      "$version_root/fixtures-after.private.json"
    if [[ $? == 0 ]] && cmp -s "$EVIDENCE_RUN_ROOT/fixtures-before.private.json" \
      "$version_root/fixtures-after.private.json"; then
      fixture_metadata_unchanged=true
    else
      cleanup_failed=true
    fi
    [[ ! -d "$result" ]] || /usr/bin/ditto "$result" "$final_result" \
      || cleanup_failed=true
    for log_name in server-build provisioner-build xcodebuild; do
      if [[ -f "$version_root/$log_name.private.log" ]]; then
        evidence_export_log "$version_root/$log_name.private.log" \
          "$other_root/Logs/$result_prefix-$log_name.log" \
          "$version_root/authentication.private.json" || cleanup_failed=true
      fi
    done
    [[ "$cleanup_failed" == false ]] || exit_code=1
    jq -n --arg version "$expected_version" --arg reference "$reference" \
      --arg phase "$last_phase" --arg outcome "$version_status" \
      --arg architecture "$runtime" --argjson exitCode "$exit_code" \
      --argjson testAttempted "$test_attempted" --argjson testExecuted "$test_executed" \
      --argjson testExitCode "$test_exit_code" \
      --argjson folderGrantVerified "$folder_grant_verified" \
      --argjson testDebuggerAllowanceVerified "$test_debugger_allowance_verified" \
      --argjson fixtureMetadataUnchanged "$fixture_metadata_unchanged" \
      --argjson forcedShutdown "$EVIDENCE_FORCED_SHUTDOWN" \
      --argjson cleanupFailed "$cleanup_failed" --argjson minimumSeconds "$minimum_seconds" \
      '{formatVersion:2,version:$version,sourceCommit:$reference,phase:$phase,outcome:$outcome,
        passed:($exitCode==0 and $testExecuted),exitCode:$exitCode,
        testAttempted:$testAttempted,testExecuted:$testExecuted,
        testExitCode:$testExitCode,architecture:$architecture,configuration:"Debug",
        requiredMinimumPlaybackSecondsPerFormat:$minimumSeconds,
        originalSandboxEnabled:(if $folderGrantVerified then true else null end),
        exactClientStateGrantVerified:$folderGrantVerified,
        testHostDebuggerAllowanceVerified:$testDebuggerAllowanceVerified,
        syntheticFixtureSizeAndModificationTimeUnchanged:$fixtureMetadataUnchanged,
        forcedShutdown:$forcedShutdown,cleanupFailed:$cleanupFailed,
        methodology:"Exact git archive with only a baseline-test overlay; matching archived server; isolated owner/database; shared generated AVI/MP4/MKV; real pinned API, relay and normal VLC video/audio outputs.",
        isolation:"Only the owned test host has one exact ClientState directory grant. All original entitlements and its leaf signing identity are retained. AppModel fails closed before saved host settings; playback is constructed directly against the owned server.",
        limitations:["This historical baseline does not inject active stream outages or shorten production tickets.",
          "The isolated Debug XCTest host enables get-task-allow for test injection and has a ClientState folder grant. It does not prove an untouched historical distribution candidate runtime.",
          "The archived server runs directly, so this is not a historical helper/autostart test.",
          "No installed app, personal library, media or Keychain state is changed.",
          "Human picture quality and hearing are not automatically assessed."]}' >"$final_summary"
    [[ $? == 0 ]] || exit_code=1
    print -r -- "Historical $expected_version outcome: $version_status ($last_phase)"
    print -r -- "Historical $expected_version summary: $final_summary"
    exit "$exit_code"
  }
  trap finish_version EXIT
  trap 'exit 130' INT TERM

  git -C "$repository_root" archive --format=tar "$reference" \
    | tar -xf - -C "$source_root"
  archived_version=$(sed -n 's:.*<Version>\([^<]*\)</Version>.*:\1:p' "$source_root/Directory.Build.props")
  [[ "$archived_version" == "$expected_version" ]] \
    || { evidence_fail archival_server_version_mismatch; exit 1; }
  /usr/bin/ditto "$repository_root/tools/macos/PlaybackHistoricalBaselineTests.swift" \
    "$source_root/clients/macos/AureliaTests/PlaybackHistoricalBaselineTests.swift"

  last_phase='matching archival server publish'
  version_status='build_failed'
  # Explicit MSBuild properties work on both historical props versions; using
  # only the environment variable would leak 1.4.0 outputs into a shared path.
  (cd "$source_root" && "$DOTNET_BIN" publish src/Aurelia.Server/Aurelia.Server.csproj \
    --configuration Release --runtime "$runtime" --self-contained true \
    -p:AureliaBuildRoot="$version_root/DotnetServerBuild" \
    -p:TreatWarningsAsErrors=true --output "$server_publish") \
    >"$version_root/server-build.private.log" 2>&1
  server="$server_publish/Aurelia.Server"
  [[ -x "$server" ]] || { evidence_fail missing_archival_server; exit 1; }
  last_phase='archival server native signature'
  while IFS= read -r -d '' binary; do
    if [[ "$(file -b "$binary")" == *Mach-O* && "$binary" != "$server" ]]; then
      /usr/bin/codesign --force --sign "$AURELIA_SIGNING_IDENTITY" \
        --options runtime --timestamp=none "$binary" \
        >>"$version_root/server-signing.private.log" 2>&1
      /usr/bin/codesign --verify --strict "$binary" \
        >>"$version_root/server-signing.private.log" 2>&1
    fi
  done < <(find "$server_publish" -type f -print0)
  /usr/bin/codesign --force --sign "$AURELIA_SIGNING_IDENTITY" \
    --options runtime --timestamp=none \
    --entitlements "$source_root/clients/macos/Configuration/ServerRuntime.entitlements" "$server" \
    >>"$version_root/server-signing.private.log" 2>&1
  /usr/bin/codesign --verify --strict "$server" \
    >>"$version_root/server-signing.private.log" 2>&1

  last_phase='offline matching-model provisioner build'
  (cd "$source_root" && "$DOTNET_BIN" publish \
    "$repository_root/tools/macos/PlaybackEvidenceProvisioner/PlaybackEvidenceProvisioner.csproj" \
    --configuration Release --runtime "$runtime" --self-contained false \
    -p:AureliaRepositoryRoot="$source_root" \
    -p:AureliaBuildRoot="$version_root/DotnetProvisionerBuild" \
    -p:TreatWarningsAsErrors=true --output "$provisioner_publish") \
    >"$version_root/provisioner-build.private.log" 2>&1

  last_phase='isolated owner setup'
  version_status='setup_failed'
  export AURELIA_EVIDENCE_OWNER_PASSWORD="historical-$(uuidgen)-synthetic-only!"
  print -r -- "$AURELIA_EVIDENCE_OWNER_PASSWORD" \
    | AURELIA_LAN_ENABLED=false ASPNETCORE_ENVIRONMENT=Production \
      "$server" setup-owner --data-dir "$server_data" --username historical-owner \
        --device-name 'Historical Synthetic Playback Evidence' --password-stdin \
        >"$version_root/owner-output.private" 2>"$version_root/setup-errors.private"
  tail -n 1 "$version_root/owner-output.private" >"$version_root/authentication.private.json"
  jq -e '.token and .sessionId and .user.role == "owner"' \
    "$version_root/authentication.private.json" >/dev/null
  last_phase='offline synthetic catalog provisioning'
  "$DOTNET_BIN" "$provisioner_publish/PlaybackEvidenceProvisioner.dll" synthetic \
    "$server_data/aurelia.db" "$EVIDENCE_RUN_ROOT/fixtures.private.json" \
    >"$version_root/provisioner-output.private" 2>&1
  http_port=$(ruby -rsocket -e 's = TCPServer.new("127.0.0.1", 0); puts s.addr[1]; s.close')
  https_port=$(ruby -rsocket -e 's = TCPServer.new("127.0.0.1", 0); puts s.addr[1]; s.close')
  [[ "$http_port" != "$https_port" ]] \
    || { evidence_fail isolated_test_ports_collided; exit 1; }
  jq -n --argjson port "$https_port" \
    '{version:2,serverName:"Aurelia Historical Baseline",lanAccessEnabled:true,lanHttpsPort:$port,
      revision:1,bonjourEnabled:false,monitoringEnabled:false,automaticBackupsEnabled:false}' \
    >"$server_data/server-settings.json"
  last_phase='owned archival HTTPS server readiness'
  AURELIA_HOST_PARENT_PID=$$ ASPNETCORE_ENVIRONMENT=Production \
    AURELIA_SERVER_NAME='Aurelia Historical Baseline' Logging__LogLevel__Default=Warning \
    "$server" --data-dir "$server_data" --urls "http://127.0.0.1:$http_port" \
      --lan --lan-port "$https_port" >"$version_root/server-output.private" 2>&1 &
  server_pid=$!
  for _ in {1..150}; do
    kill -0 "$server_pid" 2>/dev/null \
      || { evidence_fail archival_server_exited_before_readiness; exit 1; }
    if curl --silent --fail --max-time 1 "http://127.0.0.1:$http_port/api/v1/server/info" \
      >"$version_root/server-info.private.json"; then
      break
    fi
    sleep 0.2
  done
  jq -e --arg version "$expected_version" \
    '.isSetup == true and .version == $version and .name == "Aurelia Historical Baseline"' \
    "$version_root/server-info.private.json" >/dev/null
  fingerprint=$(openssl x509 -in "$server_data/server-certificate.pem" -pubkey -noout \
    | openssl pkey -pubin -outform DER | shasum -a 256 | awk '{print toupper($1)}')
  [[ ${#fingerprint} == 64 && "$fingerprint" != *[^A-F0-9]* ]] \
    || { evidence_fail missing_owned_server_pin; exit 1; }

  last_phase='signed archival Debug test host build'
  version_status='build_failed'
  "$source_root/scripts/prepare-vlckit.sh" >"$version_root/vlc-preparation.private.log" 2>&1
  # Retain the archived project's automatic signing. A concrete certificate
  # override conflicts with that mode; verify the actual leaf before launch.
  test_build_settings=(ENABLE_TESTABILITY=YES SWIFT_TREAT_WARNINGS_AS_ERRORS=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=YES)
  if [[ "$expected_version" == 1.4.1 ]]; then
    test_build_settings+=('SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) AURELIA_BASELINE_REVISIONED_PROGRESS')
  fi
  DEVELOPER_DIR="$developer_dir" xcodebuild -quiet \
    -project "$source_root/clients/macos/Aurelia.xcodeproj" -scheme Aurelia \
    -configuration Debug -destination "platform=macOS,arch=$architecture" \
    -derivedDataPath "$derived_data" -enableCodeCoverage NO \
    "${test_build_settings[@]}" build-for-testing >"$version_root/xcodebuild.private.log" 2>&1 &
  EVIDENCE_TOOL_PID=$!
  wait "$EVIDENCE_TOOL_PID"
  EVIDENCE_TOOL_PID=''
  test_host="$derived_data/Build/Products/Debug/Aurelia.app"
  evidence_copy_test_vlc "$test_host" "$derived_data/Build/Products/Debug/VLCKit.framework"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$test_host/Contents/Info.plist")" == "$expected_version" ]] \
    || { evidence_fail archival_client_version_mismatch; exit 1; }
  last_phase='exact owned ClientState test-only grant'
  version_status='setup_failed'
  evidence_grant_folder "$test_host" "$client_state" "$EVIDENCE_RUN_ROOT"
  folder_grant_verified=true
  evidence_require_test_debugger_allowance "$test_host"
  test_debugger_allowance_verified=true

  last_phase='real historical playback XCTest baseline'
  version_status='test_failed'
  export TEST_RUNNER_AURELIA_UI_TEST_MODE=playback-evidence
  export TEST_RUNNER_AURELIA_BASELINE_OWNED_TEST_STATE=YES
  # The historical AppModel's existing fail-closed preflight guard rejects this
  # TestRuns location before reading saved profile/host settings. The baseline
  # constructs the real API/controller itself; this does not enable mock APIs.
  export TEST_RUNNER_AURELIA_PREFLIGHT_TEST=1
  export TEST_RUNNER_AURELIA_DATA_DIR="$server_data"
  export TEST_RUNNER_AURELIA_BASELINE_SERVER_URL="https://127.0.0.1:$https_port"
  export TEST_RUNNER_AURELIA_BASELINE_FINGERPRINT="$fingerprint"
  export TEST_RUNNER_AURELIA_BASELINE_AUTH="$(<"$version_root/authentication.private.json")"
  export TEST_RUNNER_AURELIA_BASELINE_FIXTURES="$(jq -c 'map({format,mediaId})' "$EVIDENCE_RUN_ROOT/fixtures.private.json")"
  export TEST_RUNNER_AURELIA_BASELINE_RUN_ROOT="$client_state"
  export TEST_RUNNER_AURELIA_BASELINE_EXPECTED_SERVER_VERSION="$expected_version"
  export TEST_RUNNER_AURELIA_BASELINE_MINIMUM_SECONDS="$minimum_seconds"
  test_attempted=true
  set +e
  DEVELOPER_DIR="$developer_dir" xcodebuild -quiet \
    -project "$source_root/clients/macos/Aurelia.xcodeproj" -scheme Aurelia \
    -configuration Debug -destination "platform=macOS,arch=$architecture" \
    -derivedDataPath "$derived_data" -resultBundlePath "$result" \
    -enableCodeCoverage NO -parallel-testing-enabled NO \
    -test-timeouts-enabled YES -maximum-test-execution-time-allowance "$((minimum_seconds * 3 + 360))" \
    -only-testing:AureliaTests/PlaybackHistoricalBaselineTests \
    "${test_build_settings[@]}" test-without-building >>"$version_root/xcodebuild.private.log" 2>&1 &
  EVIDENCE_TOOL_PID=$!
  wait "$EVIDENCE_TOOL_PID"
  test_exit_code=$?
  EVIDENCE_TOOL_PID=''
  set -e
  # An invoked XCTest command is not proof that this test actually ran. Require
  # completed test counts; runner/launch failure is a separate infrastructure
  # outcome and must not be interpreted as a historical playback regression.
  if [[ -d "$result" ]] \
    && DEVELOPER_DIR="$developer_dir" xcrun xcresulttool get test-results summary \
      --path "$result" >"$version_root/test-summary.private.json" \
      2>"$version_root/test-summary-errors.private.log" \
    && jq -e '(.totalTestCount // 0) > 0
      and (((.passedTests // 0) + (.failedTests // 0)) > 0)' \
      "$version_root/test-summary.private.json" >/dev/null; then
    test_executed=true
  else
    version_status='test_infrastructure_failed'
    last_phase='XCTest launch or completed-test evidence'
    exit 1
  fi
  [[ "$test_exit_code" == 0 ]] || exit "$test_exit_code"
  version_status='passed'
  last_phase='complete'
  exit 0
fi

candidate=${1:-}
minimum_seconds=${2:-120}
[[ $# == 1 || $# == 2 ]] \
  || { evidence_fail supply_signed_candidate_and_optional_duration; exit 2; }
[[ -d "$candidate/Contents" && "$minimum_seconds" == <120-600> ]] \
  || { evidence_fail invalid_candidate_or_duration; exit 2; }
candidate=${candidate:A}
[[ -x "$DOTNET_BIN" ]] || { evidence_fail pinned_dotnet_runtime_unavailable; exit 2; }
git -C "$repository_root" cat-file -e "$reference_140^{commit}"
git -C "$repository_root" cat-file -e "$reference_141^{commit}"
runtime_parent="$HOME/Library/Caches/Aurelia/TestRuns"
mkdir -p "$runtime_parent" "$other_root/Test Results" "$other_root/Logs"
EVIDENCE_RUN_ROOT=$(mktemp -d "$runtime_parent/playback-evidence-historical-XXXXXXXX")
export EVIDENCE_RUN_ROOT
run_id=${EVIDENCE_RUN_ROOT:t}
last_phase='configuration'
comparison_failed=false
EVIDENCE_FORCED_SHUTDOWN=false
EVIDENCE_WRAPPER_CHILD_PID=''
final_comparison="$other_root/Test Results/Aurelia-Playback-Historical-Comparison-$run_id.json"

finish_comparison() {
  local exit_code=$? metadata_unchanged=false preservation_failed=false
  set +e
  if [[ -n "$EVIDENCE_WRAPPER_CHILD_PID" ]]; then
    evidence_stop_pid "$EVIDENCE_WRAPPER_CHILD_PID" || preservation_failed=true
  fi
  evidence_stop_owned_build_tools || preservation_failed=true
  evidence_stop_test_hosts || preservation_failed=true
  evidence_stop_owned_servers || preservation_failed=true
  if [[ -f "$EVIDENCE_RUN_ROOT/fixtures-before.private.json" ]]; then
    evidence_fixture_snapshot "$EVIDENCE_RUN_ROOT/fixtures.private.json" \
      "$EVIDENCE_RUN_ROOT/fixtures-after.private.json"
    if [[ $? == 0 ]] && cmp -s "$EVIDENCE_RUN_ROOT/fixtures-before.private.json" \
      "$EVIDENCE_RUN_ROOT/fixtures-after.private.json"; then
      metadata_unchanged=true
    else
      preservation_failed=true
    fi
  fi
  [[ "$preservation_failed" == false ]] || exit_code=1
  version_summaries=()
  for version in 1.4.0 1.4.1; do
    version_summary="$other_root/Test Results/Aurelia-Playback-Historical-$version-$run_id.json"
    [[ ! -f "$version_summary" ]] || version_summaries+=("$version_summary")
  done
  if (( ${#version_summaries} > 0 )); then
    jq -s '.' "${version_summaries[@]}" >"$EVIDENCE_RUN_ROOT/version-summaries.private.json"
  else
    print -r -- '[]' >"$EVIDENCE_RUN_ROOT/version-summaries.private.json"
  fi
  jq -n --arg phase "$last_phase" --argjson exitCode "$exit_code" \
    --argjson fixtureMetadataUnchanged "$metadata_unchanged" \
    --argjson minimumSeconds "$minimum_seconds" \
    --slurpfile versions "$EVIDENCE_RUN_ROOT/version-summaries.private.json" \
    '{formatVersion:1,phase:$phase,passed:($exitCode==0 and ($versions[0]|length)==2
        and ($versions[0]|all(.passed))),exitCode:$exitCode,
      requiredMinimumPlaybackSecondsPerFormat:$minimumSeconds,versions:$versions[0],
      syntheticFixtureSizeAndModificationTimeUnchanged:$fixtureMetadataUnchanged,
      comparison:"Both exact historical versions are attempted sequentially, even if one baseline fails. Build/setup failure is distinguished from an executed test failure. A failure is evidence for its recorded phase, not by itself proof of a version regression.",
      retainedArtifacts:"Only XCTest bundles, redacted build logs and closed-schema summaries.",
      cleanup:"All owned historical apps, published servers, synthetic source/state, certificates and private setup logs are removed after results are retained. Nothing is installed or copied for rollback."}' \
    >"$final_comparison"
  [[ $? == 0 ]] || exit_code=1
  evidence_remove_owned_run "$EVIDENCE_RUN_ROOT" || exit_code=1
  print -r -- "Historical playback comparison: $final_comparison"
  exit "$exit_code"
}
trap finish_comparison EXIT
trap 'exit 130' INT TERM

last_phase='original signing identity resolution'
AURELIA_SIGNING_IDENTITY=$(evidence_signing_identity "$candidate" "$EVIDENCE_RUN_ROOT")
export AURELIA_SIGNING_IDENTITY
last_phase='one shared synthetic fixture generation'
mkdir -p "$EVIDENCE_RUN_ROOT/Fixtures"
DEVELOPER_DIR="$developer_dir" xcrun --sdk macosx swiftc \
  -swift-version 6 -target "$architecture-apple-macos26.0" \
  -warnings-as-errors -parse-as-library \
  "$repository_root/tools/macos/FullChainFixtureGenerator.swift" \
  "$repository_root/clients/macos/AureliaTests/FullChainSyntheticMedia.swift" \
  -o "$EVIDENCE_RUN_ROOT/FullChainFixtureGenerator" \
  >"$EVIDENCE_RUN_ROOT/generator-build.private.log" 2>&1
"$EVIDENCE_RUN_ROOT/FullChainFixtureGenerator" "$EVIDENCE_RUN_ROOT/Fixtures" \
  >"$EVIDENCE_RUN_ROOT/fixtures.private.json" 2>"$EVIDENCE_RUN_ROOT/generator-errors.private.log"
jq -e 'length == 3 and (map(.format)|sort) == ["AVI","MKV","MP4"]
  and all(.[]; (.mediaId|type)=="string" and (.path|type)=="string")' \
  "$EVIDENCE_RUN_ROOT/fixtures.private.json" >/dev/null
evidence_fixture_snapshot "$EVIDENCE_RUN_ROOT/fixtures.private.json" \
  "$EVIDENCE_RUN_ROOT/fixtures-before.private.json"

for version in 1.4.0 1.4.1; do
  reference=$reference_140
  [[ "$version" == 1.4.0 ]] || reference=$reference_141
  last_phase="historical $version"
  print -r -- "Starting exact historical $version synthetic playback baseline."
  /bin/zsh "$script_path" --run-version "$EVIDENCE_RUN_ROOT" "$reference" "$version" "$minimum_seconds" &
  EVIDENCE_WRAPPER_CHILD_PID=$!
  set +e
  wait "$EVIDENCE_WRAPPER_CHILD_PID"
  version_exit_code=$?
  set -e
  EVIDENCE_WRAPPER_CHILD_PID=''
  [[ "$version_exit_code" == 0 ]] || comparison_failed=true
done
last_phase='complete'
[[ "$comparison_failed" == false ]] || exit 1
