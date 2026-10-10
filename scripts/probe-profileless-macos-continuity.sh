#!/bin/zsh
# Check ordinary Mac Keychain continuity across the actual entitlement shape
# change. The baseline needs the real bundle ID solely for profile authorization.
# No real credential, production host group, app setting, or data file is read.
set -euo pipefail
repository_root=${0:A:h:h}
source "$repository_root/scripts/workspace-paths.sh"
team_identifier=B5N7JVK37J
bundle_identifier=com.lucas.aurelia.media
signing_identity=${AURELIA_SIGNING_IDENTITY:-}
provisioning_profile=${AURELIA_PROVISIONING_PROFILE:-/Applications/Aurelia.app/Contents/embedded.provisionprofile}
[[ -r "$provisioning_profile" ]] || {
  print -u2 "A valid matching baseline provisioning profile is required for this continuity test."
  exit 2
}
mkdir -p "$other_root/Logs" "$HOME/Library/Caches/Aurelia/TestRuns"
probe_root=$(mktemp -d "$HOME/Library/Caches/Aurelia/TestRuns/Profileless-Continuity.XXXXXX")
chmod 700 "$probe_root"
log="$other_root/Logs/Profileless-Continuity-${probe_root:t}.log"
candidate="$probe_root/ProfilelessProbe.app"
helper="$candidate/Contents/Helpers/ProfilelessHostProbe.app"
binary="$candidate/Contents/MacOS/ProfilelessProbe"
helper_binary="$helper/Contents/MacOS/ProfilelessProbe"
identifier=$(uuidgen)
probe_pid=''
credential_written=false
cleanup_complete=false
baseline_entitlements="$probe_root/baseline.entitlements"
active_binary="$binary"

stop_probe() {
  if [[ -n "$probe_pid" ]] && kill -0 "$probe_pid" 2>/dev/null; then
    kill -TERM "$probe_pid" 2>/dev/null || true
    for _ in {1..20}; do
      kill -0 "$probe_pid" 2>/dev/null || break
      sleep 0.1
    done
    kill -KILL "$probe_pid" 2>/dev/null || true
    wait "$probe_pid" 2>/dev/null || true
  fi
  probe_pid=''
}

run_probe() {
  "$active_binary" "$@" >>"$log" 2>&1 &
  probe_pid=$!
  for _ in {1..150}; do
    kill -0 "$probe_pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$probe_pid" 2>/dev/null; then
    print "FAIL: bounded synthetic probe timed out." >>"$log"
    stop_probe
    return 1
  fi
  local result=0
  wait "$probe_pid" || result=$?
  probe_pid=''
  return "$result"
}

cleanup() {
  local exit_code=$?
  [[ "$cleanup_complete" == true ]] && return
  cleanup_complete=true
  set +e
  stop_probe
  active_binary="$binary"
  if [[ -x "$binary" ]]; then
    run_probe group-delete "$identifier" || true
  fi
  if [[ "$credential_written" == true && -x "$binary" ]]; then
    # Restore only this synthetic app's original authorization if necessary.
    /usr/bin/ditto "$provisioning_profile" "$candidate/Contents/embedded.provisionprofile"
    /usr/bin/codesign --force --sign "$signing_identity" --options runtime --timestamp=none \
      --entitlements "$baseline_entitlements" "$candidate" >>"$log" 2>&1
    run_probe delete "$identifier" || print "FAIL: synthetic credential cleanup requires inspection." >>"$log"
  fi
  if [[ "$probe_root" == "$HOME/Library/Caches/Aurelia/TestRuns/Profileless-Continuity."* ]]; then
    find "$probe_root" -depth -delete
  fi
  print "Continuity probe exit status: $exit_code" >>"$log"
}
trap cleanup EXIT

/bin/zsh "$repository_root/scripts/verify-profileless-macos-identity.sh" \
  "$signing_identity" "$team_identifier" "$probe_root/Identity Verification" >"$log" 2>&1
/usr/bin/security cms -D -i "$provisioning_profile" >"$probe_root/profile.plist"
profile_id=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$probe_root/profile.plist")
profile_team=$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$probe_root/profile.plist")
[[ "$profile_id" == "$team_identifier.$bundle_identifier" && "$profile_team" == "$team_identifier" ]] || {
  print -u2 "The baseline profile does not authorize Aurelia's identity."
  exit 1
}
profile_expiration=$(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$probe_root/profile.plist")
profile_expiration_epoch=$(/bin/date -j -f '%a %b %d %H:%M:%S %Z %Y' "$profile_expiration" +%s)
[[ "$profile_expiration_epoch" -gt $(/bin/date +%s) ]] || {
  print -u2 "The baseline provisioning profile is expired; no credential was written."
  exit 1
}
profile_identity=$(/usr/bin/plutil -extract DeveloperCertificates.0 raw -o - "$probe_root/profile.plist" \
  | /usr/bin/base64 -D | /usr/bin/openssl x509 -inform DER -noout -fingerprint -sha1 \
  | /usr/bin/sed -E 's/^[^=]*=//; s/://g' | /usr/bin/tr '[:lower:]' '[:upper:]')
[[ "$signing_identity" == "$profile_identity" ]] || {
  print -u2 "The selected identity is not authorized by the baseline profile."
  exit 1
}
mkdir -p "$candidate/Contents/MacOS" "$helper/Contents/MacOS"
for app in "$candidate" "$helper"; do
  /usr/bin/ditto "$repository_root/tools/macos/ProfilelessProbe-Info.plist" "$app/Contents/Info.plist"
done
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_identifier" "$candidate/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.aurelia.profileless-probe.host' "$helper/Contents/Info.plist"
DEVELOPER_DIR="$developer_dir" /usr/bin/xcrun swiftc -warnings-as-errors \
  "$repository_root/tools/macos/ProfilelessContinuityProbe.swift" -o "$binary"
/usr/bin/ditto "$binary" "$helper_binary"
/usr/bin/codesign --force --sign "$signing_identity" --options runtime --timestamp=none \
  --entitlements "$repository_root/tools/macos/ProfilelessProbe.entitlements" "$helper"
/usr/bin/ditto "$repository_root/clients/macos/Configuration/Aurelia.entitlements" "$baseline_entitlements"
/usr/libexec/PlistBuddy -c 'Set :com.apple.security.application-groups:0 B5N7JVK37J.com.aurelia.distribution-probe' "$baseline_entitlements"
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $team_identifier.$bundle_identifier" "$baseline_entitlements"
/usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $team_identifier" "$baseline_entitlements"
/usr/bin/ditto "$provisioning_profile" "$candidate/Contents/embedded.provisionprofile"
/usr/bin/codesign --force --sign "$signing_identity" --options runtime --timestamp=none \
  --entitlements "$baseline_entitlements" "$candidate"
/usr/bin/codesign --verify --deep --strict "$candidate"
credential_written=true
run_probe write "$identifier"
# Only the profile in the validated, synthetic app bundle is removed.
/bin/rm -- "$candidate/Contents/embedded.provisionprofile"
/usr/bin/codesign --force --sign "$signing_identity" --options runtime --timestamp=none \
  --entitlements "$repository_root/tools/macos/ProfilelessProbe.entitlements" "$candidate"
/usr/bin/codesign --verify --deep --strict "$candidate"
run_probe read-update-delete "$identifier"
credential_written=false
active_binary="$helper_binary"
run_probe group-read "$identifier"
print "PASS: synthetic credential survived the profile/entitlement change and a profileless helper shared its isolated group." >>"$log"
print "Profileless continuity log: $log"
