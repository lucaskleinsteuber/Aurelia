#!/bin/zsh
# Source from a zsh evidence wrapper. Helpers never disable the app sandbox,
# choose a different signing identity, or touch an installed application.

evidence_fail() {
  print -u2 -r -- "Playback evidence preparation failed: $1"
  return 1
}

evidence_assert_owned_run() {
  local owned_root=${1:-} owned_parent="$HOME/Library/Caches/Aurelia/TestRuns"
  [[ -n "$owned_root" \
    && ( "$owned_root" == "$owned_parent/playback-evidence-"* \
      || "$owned_root" == "$owned_parent/full-chain-"* ) \
    && "${owned_root:h}" == "$owned_parent" && -d "$owned_root" \
    && ! -L "$owned_root" && "${owned_root:A}" == "$owned_root" ]] \
    || { evidence_fail invalid_owned_run; return 1; }
}

evidence_assert_owned_path() {
  local owned_path=${1:-} owned_root=${2:-${EVIDENCE_RUN_ROOT:-}}
  evidence_assert_owned_run "$owned_root" || return 1
  [[ "$owned_path" == "$owned_root/"* && ! -L "$owned_path" \
    && "${owned_path:A}" == "$owned_path" ]] \
    || { evidence_fail invalid_owned_path; return 1; }
}

# Prints only the original leaf certificate SHA-1. The supplied candidate is
# read-only; certificates and diagnostic output belong to the private run.
evidence_signing_identity() {
  local host=${1:-} owned_root=${2:-} certificate_root identity selected
  evidence_assert_owned_run "$owned_root" || return 1
  [[ -d "$host/Contents" ]] \
    || { evidence_fail missing_signed_host; return 1; }
  certificate_root=$(mktemp -d "$owned_root/identity-XXXXXXXX") || return 1
  /usr/bin/codesign --verify --deep --strict "$host" \
    >"$certificate_root/signature.private.log" 2>&1 \
    || { evidence_fail original_host_signature; return 1; }
  # The optional prefix must be joined with '='; a separated argument is parsed
  # as a code path by codesign and fails before extracting the certificate.
  /usr/bin/codesign --display --extract-certificates="$certificate_root/leaf-" "$host" \
    >>"$certificate_root/signature.private.log" 2>&1 \
    || { evidence_fail original_leaf_certificate; return 1; }
  identity=$(openssl x509 -inform DER -in "$certificate_root/leaf-0" \
    -noout -fingerprint -sha1 | awk -F= '{ gsub(":", "", $2); print toupper($2) }') \
    || { evidence_fail original_leaf_fingerprint; return 1; }
  selected=${AURELIA_SIGNING_IDENTITY:-$identity}
  [[ "$identity" != *[^A-F0-9]* && ${#identity} == 40 && "$selected" == "$identity" ]] \
    || { evidence_fail mismatched_original_signing_identity; return 1; }
  /usr/bin/security find-identity -v -p codesigning \
    | awk -v identity="$identity" '$2 == identity { found=1 } END { exit !found }' \
    || { evidence_fail original_identity_unavailable; return 1; }
  print -r -- "$identity"
}

# XCTest injects its bundle into the isolated host. Release distribution builds
# intentionally omit this debugging entitlement; only build-for-testing enables
# it, without changing the candidate or disabling its hardened runtime setting.
evidence_require_test_debugger_allowance() {
  local host=${1:-} verification_root
  evidence_assert_owned_path "$host" || return 1
  verification_root=$(mktemp -d "$EVIDENCE_RUN_ROOT/test-debugger-XXXXXXXX") || return 1
  /usr/bin/codesign --display --entitlements - --xml "$host" \
    >"$verification_root/entitlements.private.plist" 2>"$verification_root/signature.private.log" \
    || { evidence_fail extract_test_debugger_entitlements; return 1; }
  /usr/bin/plutil -convert json -o "$verification_root/entitlements.private.json" \
    "$verification_root/entitlements.private.plist" \
    || { evidence_fail test_debugger_entitlement_json; return 1; }
  jq -e '.["com.apple.security.get-task-allow"] == true' \
    "$verification_root/entitlements.private.json" >/dev/null \
    || { evidence_fail isolated_test_host_debugger_allowance_missing; return 1; }
}

# Re-signs only an owned outer test host, with one exact owned directory grant.
# Every original entitlement and the original leaf identity must be retained.
evidence_grant_folder() {
  local host=${1:-} folder=${2:-} owned_root=${3:-} grant_root original modified verified
  local original_json modified_json verified_json identity verified_identity
  local key='com.apple.security.temporary-exception.files.absolute-path.read-write'
  evidence_assert_owned_path "$host" "$owned_root" || return 1
  evidence_assert_owned_path "$folder" "$owned_root" || return 1
  [[ -d "$host/Contents" && -d "$folder" ]] \
    || { evidence_fail missing_exact_grant_target; return 1; }
  identity=$(evidence_signing_identity "$host" "$owned_root") || return 1
  grant_root=$(mktemp -d "$owned_root/folder-grant-XXXXXXXX") || return 1
  original="$grant_root/original.private.plist"
  modified="$grant_root/modified.private.plist"
  verified="$grant_root/verified.private.plist"
  original_json="$grant_root/original.private.json"
  modified_json="$grant_root/modified.private.json"
  verified_json="$grant_root/verified.private.json"
  /usr/bin/codesign --display --entitlements - --xml "$host" \
    >"$original" 2>"$grant_root/signature.private.log" \
    || { evidence_fail extract_original_entitlements; return 1; }
  /usr/bin/plutil -lint "$original" >/dev/null \
    || { evidence_fail original_entitlement_plist; return 1; }
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$original")" == true ]] \
    || { evidence_fail original_sandbox_not_enabled; return 1; }
  if /usr/libexec/PlistBuddy -c "Print :$key" "$original" >/dev/null 2>&1; then
    evidence_fail preexisting_filesystem_exception
    return 1
  fi
  /usr/bin/ditto "$original" "$modified" \
    || { evidence_fail copy_original_entitlements; return 1; }
  /usr/libexec/PlistBuddy -c "Add :$key array" "$modified" \
    || { evidence_fail add_exact_grant_array; return 1; }
  /usr/libexec/PlistBuddy -c "Add :${key}:0 string $folder/" "$modified" \
    || { evidence_fail add_exact_grant_path; return 1; }
  /usr/bin/plutil -convert json -o "$original_json" "$original" \
    || { evidence_fail original_entitlement_json; return 1; }
  /usr/bin/plutil -convert json -o "$modified_json" "$modified" \
    || { evidence_fail modified_entitlement_json; return 1; }
  jq -e --slurp --arg key "$key" --arg path "$folder/" \
    '.[0] as $original | .[1] as $test |
     ($original["com.apple.security.app-sandbox"] == true) and
     (($test | del(.[$key])) == $original) and ($test[$key] == [$path])' \
    "$original_json" "$modified_json" >/dev/null \
    || { evidence_fail verify_only_exact_grant_added; return 1; }
  /usr/bin/codesign --force --sign "$identity" --timestamp=none \
    --preserve-metadata=identifier,requirements,flags,runtime,launch-constraints,library-constraints \
    --entitlements "$modified" "$host" >>"$grant_root/signature.private.log" 2>&1 \
    || { evidence_fail resign_outer_owned_host; return 1; }
  /usr/bin/codesign --verify --deep --strict "$host" \
    >>"$grant_root/signature.private.log" 2>&1 \
    || { evidence_fail verify_owned_host_signature; return 1; }
  /usr/bin/codesign --display --entitlements - --xml "$host" \
    >"$verified" 2>>"$grant_root/signature.private.log" \
    || { evidence_fail extract_signed_entitlements; return 1; }
  /usr/bin/plutil -convert json -o "$verified_json" "$verified" \
    || { evidence_fail signed_entitlement_json; return 1; }
  jq -e --slurp '.[0] == .[1]' "$modified_json" "$verified_json" >/dev/null \
    || { evidence_fail signed_entitlements_changed; return 1; }
  verified_identity=$(evidence_signing_identity "$host" "$owned_root") || return 1
  [[ "$verified_identity" == "$identity" ]] \
    || { evidence_fail signed_leaf_identity_changed; return 1; }
}

# XCTest resolves a standalone VLCKit.framework. Replace only that run-owned
# framework with the embedded, already-signed copy produced by the same build.
evidence_copy_test_vlc() {
  local host=${1:-} standalone=${2:-} embedded="$1/Contents/Frameworks/VLCKit.framework"
  evidence_assert_owned_path "$host" || return 1
  evidence_assert_owned_path "$standalone" || return 1
  [[ -d "$embedded" && -d "$standalone" && ! -L "$embedded" ]] \
    || { evidence_fail missing_owned_vlc_copies; return 1; }
  /usr/bin/codesign --verify --strict "$embedded" >/dev/null 2>&1 \
    || { evidence_fail embedded_vlc_signature; return 1; }
  /usr/bin/ditto "$embedded" "$standalone" \
    || { evidence_fail copy_owned_vlc; return 1; }
  /usr/bin/codesign --verify --strict "$standalone" >/dev/null 2>&1 \
    || { evidence_fail standalone_vlc_signature; return 1; }
}

# A packaged candidate may live outside the run. Register only the exact child
# executable and its run-owned --data-dir before using the common stop helper.
evidence_register_server_pid() {
  local owned_pid=${1:-} executable=${2:-} data_root=${3:-} command_line
  evidence_assert_owned_path "$data_root" || return 1
  [[ "$owned_pid" == <2-> && -x "$executable" && "${executable:A}" == "$executable" ]] \
    || { evidence_fail invalid_owned_server_registration; return 1; }
  command_line=$(ps -p "$owned_pid" -o command= 2>/dev/null) \
    || { evidence_fail owned_server_registration_exited; return 1; }
  [[ "$command_line" == "$executable "* && "$command_line" == *" --data-dir $data_root "* ]] \
    || { evidence_fail owned_server_registration_mismatch; return 1; }
  EVIDENCE_SERVER_PID=$owned_pid
  EVIDENCE_SERVER_EXECUTABLE=$executable
  EVIDENCE_SERVER_DATA_ROOT=$data_root
}

# Direct candidate-server cleanup. PID, owner, command, exact executable,
# run-owned data argument and process start time are checked without printing
# any process arguments. Recheck immediately before a bounded forced shutdown.
evidence_stop_packaged_server() {
  local owned_pid=${1:-} executable=${2:-} data_root=${3:-} owned_root=${4:-} code
  evidence_assert_owned_path "$data_root" "$owned_root" || return 1
  [[ "$owned_pid" == <2-> && -x "$executable" && "${executable:A}" == "$executable" ]] \
    || { evidence_fail invalid_owned_packaged_server; return 1; }
  if ruby -ropen3 -e '
    begin
    pid = Integer(ARGV[0], 10)
    executable, data = ARGV[1], ARGV[2]
    inspect = lambda do
      command, command_result = Open3.capture2("/bin/ps", "-p", pid.to_s, "-o", "command=")
      next nil unless command_result.success?
      owner, owner_result = Open3.capture2("/bin/ps", "-p", pid.to_s, "-o", "uid=")
      started, start_result = Open3.capture2("/bin/ps", "-p", pid.to_s, "-o", "lstart=")
      state, state_result = Open3.capture2("/bin/ps", "-p", pid.to_s, "-o", "stat=")
      next nil unless owner_result.success? && start_result.success? && state_result.success?
      raise "not owned" unless owner.strip == Process.uid.to_s
      next [command.rstrip, started.strip, state.strip] if state.strip.start_with?("Z")
      raise "wrong executable" unless command.start_with?(executable + " ")
      argument = " --data-dir " + data
      raise "wrong data" unless command.include?(argument + " ") || command.rstrip.end_with?(argument)
      [command.rstrip, started.strip, state.strip]
    end
    original = inspect.call
    exit 0 unless original
    exit 0 if original[2].start_with?("Z")
    Process.kill("TERM", pid)
    100.times do
      sleep 0.1
      current = inspect.call
      exit 0 unless current
      exit 0 if current[2].start_with?("Z")
      raise "changed process" unless current[0, 2] == original[0, 2]
    end
    current = inspect.call
    exit 0 unless current
    raise "changed process" unless current[0, 2] == original[0, 2]
    Process.kill("KILL", pid)
    exit 3
  rescue Errno::ESRCH
    exit 0
  rescue StandardError
    exit 1
    end
  ' "$owned_pid" "$executable" "$data_root"; then
    wait "$owned_pid" 2>/dev/null || true
    return 0
  else
    code=$?
    if [[ "$code" == 3 ]]; then
      EVIDENCE_FORCED_SHUTDOWN=true
      wait "$owned_pid" 2>/dev/null || true
      evidence_fail forced_owned_packaged_server_shutdown
    else
      evidence_fail packaged_server_identity_check_failed
    fi
    return 1
  fi
}

# Only executable commands belonging to the active canonical run can be stopped.
# A known wrapper child is separately admitted only when its exact run argument
# and executable script are present. Never pgrep/kill installed helpers globally.
evidence_collect_stopped_pid() {
  local owned_pid=${1:-} child_exit_code=0
  wait "$owned_pid" 2>/dev/null || child_exit_code=$?
  # The full-chain Ruby supervisor owns/reaps its server. A nonzero supervisor
  # exit (including its forced-server-shutdown result) must fail the gate.
  # Test hosts are not necessarily direct shell children, so their wait status
  # is not used as test evidence; XCTest owns that completion check instead.
  if [[ "$owned_pid" == "${EVIDENCE_CONTROL_PID:-}" && "$child_exit_code" != 0 ]]; then
    evidence_fail owned_server_supervisor_exit_failed
    return 1
  fi
  return 0
}

evidence_stop_pid() {
  local owned_pid=${1:-} command_line process_state
  evidence_assert_owned_run "${EVIDENCE_RUN_ROOT:-}" || return 1
  [[ "$owned_pid" == <2-> ]] || { evidence_fail invalid_owned_pid; return 1; }
  if ! kill -0 "$owned_pid" 2>/dev/null; then
    if [[ "$owned_pid" == "${EVIDENCE_CONTROL_PID:-}" ]]; then
      evidence_collect_stopped_pid "$owned_pid"
      return $?
    fi
    return 0
  fi
  process_state=$(ps -p "$owned_pid" -o stat= 2>/dev/null || true)
  if [[ "${process_state// /}" == Z* ]]; then
    evidence_collect_stopped_pid "$owned_pid"
    return $?
  fi
  command_line=$(ps -p "$owned_pid" -o command= 2>/dev/null) || return 0
  if [[ "$command_line" != "$EVIDENCE_RUN_ROOT/"* ]]; then
    if [[ "$owned_pid" == "${EVIDENCE_SERVER_PID:-}" \
      && "$command_line" == "${EVIDENCE_SERVER_EXECUTABLE:-} "* \
      && "$command_line" == *" --data-dir ${EVIDENCE_SERVER_DATA_ROOT:-} "* ]]; then
      evidence_stop_packaged_server "$owned_pid" "$EVIDENCE_SERVER_EXECUTABLE" \
        "$EVIDENCE_SERVER_DATA_ROOT" "$EVIDENCE_RUN_ROOT"
      return $?
    fi
    [[ ( "$owned_pid" == "${EVIDENCE_WRAPPER_CHILD_PID:-}" \
        && "$command_line" == *"/scripts/test-playback-historical.sh --run-version $EVIDENCE_RUN_ROOT "* ) \
      || ( "$owned_pid" == "${EVIDENCE_TOOL_PID:-}" \
        && "$command_line" == *xcodebuild\ * \
        && ( "$command_line" == *" -project $EVIDENCE_RUN_ROOT/"* \
          || ( -n "${EVIDENCE_PROJECT_PATH:-}" \
            && "$command_line" == *" -project $EVIDENCE_PROJECT_PATH "* \
            && "$command_line" == *" -derivedDataPath $EVIDENCE_RUN_ROOT/"* ) ) ) \
      || ( "$owned_pid" == "${EVIDENCE_CONTROL_PID:-}" \
        && "$command_line" == *"/scripts/full-chain-server-control.rb ${EVIDENCE_SERVER_EXECUTABLE:-} ${EVIDENCE_SERVER_DATA_ROOT:-} "* \
        && "$command_line" == *" $EVIDENCE_RUN_ROOT/server-control.private.json $EVIDENCE_RUN_ROOT/server-output.private "* ) \
      || ( "$owned_pid" == "${EVIDENCE_WATCHDOG_PID:-}" \
        && "$command_line" == *"/scripts/playback-authorized-read-watchdog.rb "* \
        && "$command_line" == *" $EVIDENCE_RUN_ROOT/ServerData $EVIDENCE_RUN_ROOT $EVIDENCE_RUN_ROOT/source-read-deadline.private" ) ]] \
      || { evidence_fail pid_not_owned_by_run; return 1; }
  fi
  # The admitted command may exit during cleanup. Validate its owner and start
  # time too, and recheck before any forced signal instead of trusting a reused
  # numeric PID. A normal zombie child is already stopped, not a forced failure.
  local stop_code
  if ruby -ropen3 -e '
    begin
      pid = Integer(ARGV[0], 10)
      expected = ARGV[1]
      inspect = lambda do
        command, result = Open3.capture2("/bin/ps", "-p", pid.to_s, "-o", "command=")
        next nil unless result.success?
        owner, owner_result = Open3.capture2("/bin/ps", "-p", pid.to_s, "-o", "uid=")
        started, start_result = Open3.capture2("/bin/ps", "-p", pid.to_s, "-o", "lstart=")
        state, state_result = Open3.capture2("/bin/ps", "-p", pid.to_s, "-o", "stat=")
        next nil unless owner_result.success? && start_result.success? && state_result.success?
        raise "not owned" unless owner.strip == Process.uid.to_s
        next [command.rstrip, started.strip, state.strip] if state.strip.start_with?("Z")
        raise "changed command" unless command.rstrip == expected
        [command.rstrip, started.strip, state.strip]
      end
      original = inspect.call
      exit 0 unless original
      exit 0 if original[2].start_with?("Z")
      Process.kill("TERM", pid)
      100.times do
        sleep 0.1
        current = inspect.call
        exit 0 unless current
        exit 0 if current[2].start_with?("Z")
        raise "changed process" unless current[0, 2] == original[0, 2]
      end
      current = inspect.call
      exit 0 unless current
      raise "changed process" unless current[0, 2] == original[0, 2]
      Process.kill("KILL", pid)
      exit 3
    rescue Errno::ESRCH
      exit 0
    rescue StandardError
      exit 1
    end
  ' "$owned_pid" "$command_line"; then
    evidence_collect_stopped_pid "$owned_pid"
    return $?
  else
    stop_code=$?
    if [[ "$stop_code" == 3 ]]; then
      EVIDENCE_FORCED_SHUTDOWN=true
      wait "$owned_pid" 2>/dev/null || true
      evidence_fail forced_owned_process_shutdown
    else
      evidence_fail owned_process_identity_check_failed
    fi
    return 1
  fi
}

evidence_stop_test_hosts() {
  local test_pid command_line failed=0
  evidence_assert_owned_run "${EVIDENCE_RUN_ROOT:-}" || return 1
  for test_pid in $(pgrep -x Aurelia 2>/dev/null || true); do
    command_line=$(ps -p "$test_pid" -o command= 2>/dev/null || true)
    if [[ "$command_line" == "$EVIDENCE_RUN_ROOT/"* ]]; then
      evidence_stop_pid "$test_pid" || failed=1
    fi
  done
  return "$failed"
}

evidence_stop_owned_servers() {
  local server_pid command_line server_data version failed=0
  evidence_assert_owned_run "${EVIDENCE_RUN_ROOT:-}" || return 1
  for server_pid in $(pgrep -x Aurelia.Server 2>/dev/null || true); do
    command_line=$(ps -p "$server_pid" -o command= 2>/dev/null || true)
    if [[ "$command_line" == "$EVIDENCE_RUN_ROOT/"* ]]; then
      # Historical executables and their data directories have no spaces in
      # this canonical run tree. Stop only the expected published-server path.
      for version in 1.4.0 1.4.1; do
        server_data="$EVIDENCE_RUN_ROOT/$version/ServerData"
        if [[ "$command_line" == "$EVIDENCE_RUN_ROOT/$version/PublishedServer/Aurelia.Server "* ]]; then
          evidence_stop_packaged_server "$server_pid" \
            "$EVIDENCE_RUN_ROOT/$version/PublishedServer/Aurelia.Server" \
            "$server_data" "$EVIDENCE_RUN_ROOT" || failed=1
        fi
      done
    fi
  done
  return "$failed"
}

evidence_stop_owned_build_tools() {
  local tool_pid command_line failed=0 original_tool_pid=${EVIDENCE_TOOL_PID:-}
  evidence_assert_owned_run "${EVIDENCE_RUN_ROOT:-}" || return 1
  for tool_pid in $(pgrep -x xcodebuild 2>/dev/null || true); do
    command_line=$(ps -p "$tool_pid" -o command= 2>/dev/null || true)
    if [[ ( "$command_line" == *" -project $EVIDENCE_RUN_ROOT/"* \
      || ( -n "${EVIDENCE_PROJECT_PATH:-}" \
        && "$command_line" == *" -project $EVIDENCE_PROJECT_PATH "* ) ) \
      && "$command_line" == *" -derivedDataPath $EVIDENCE_RUN_ROOT/"* ]]; then
      EVIDENCE_TOOL_PID=$tool_pid
      evidence_stop_pid "$tool_pid" || failed=1
    fi
  done
  EVIDENCE_TOOL_PID=$original_tool_pid
  return "$failed"
}

# Metadata-only preservation check. Ruby never opens fixture content; private
# snapshots include paths for comparison and must not be exported as evidence.
evidence_fixture_snapshot() {
  local manifest=${1:-} output=${2:-}
  evidence_assert_owned_path "$manifest" || return 1
  evidence_assert_owned_path "$output" || return 1
  ruby -rjson -e '
    rows = JSON.parse(File.read(ARGV[0]))
    result = rows.map do |row|
      path = row.fetch("path")
      raise "non-owned fixture" unless path.start_with?(ARGV[2] + "/Fixtures/")
      metadata = File.lstat(path)
      raise "non-regular fixture" unless metadata.file? && !metadata.symlink?
      {format: row.fetch("format"), mediaId: row.fetch("mediaId"), path: path,
       size: metadata.size, modifiedSeconds: metadata.mtime.to_i,
       modifiedNanoseconds: metadata.mtime.nsec}
    end
    File.write(ARGV[1], JSON.generate(result.sort_by { |row| row[:format] }))
  ' "$manifest" "$output" "$EVIDENCE_RUN_ROOT" \
    || { evidence_fail fixture_metadata_snapshot; return 1; }
}

# Build logs are retained; private setup/server logs and credentials are not.
# Known test credentials are scrubbed even if an Xcode diagnostic echoes them.
evidence_export_log() {
  local input=${1:-} output=${2:-} authentication=${3:-}
  evidence_assert_owned_path "$input" || return 1
  [[ -f "$input" && "$output" == /* && ! -L "$output" ]] \
    || { evidence_fail invalid_evidence_log; return 1; }
  ruby -rjson -e '
    values = [ENV["AURELIA_EVIDENCE_OWNER_PASSWORD"]].compact
    if !ARGV[2].empty? && File.file?(ARGV[2])
      auth = JSON.parse(File.read(ARGV[2]))
      values += [auth["token"], auth["sessionId"]].compact
    end
    data = File.read(ARGV[0])
    values.each { |value| data = data.gsub(value, "[redacted-owned-test-credential]") unless value.empty? }
    source = ENV["AURELIA_EVIDENCE_AUTHORIZED_SOURCE_FILE"]
    data = data.gsub(source, "[redacted-authorized-source]") if source && !source.empty?
    File.write(ARGV[1], data)
  ' "$input" "$output" "$authentication" \
    || { evidence_fail export_redacted_build_log; return 1; }
}

evidence_remove_owned_run() {
  local owned_root=${1:-}
  evidence_assert_owned_run "$owned_root" || return 1
  if ps -ax -o command= | awk -v root="$owned_root" \
    'index($0, root "/") > 0 || index($0, " --run-version " root " ") > 0 { found=1 }
     END { exit !found }'; then
    evidence_fail owned_run_still_has_active_processes
    return 1
  fi
  /bin/rm -rf -- "$owned_root"
}
