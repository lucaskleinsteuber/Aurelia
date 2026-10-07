#!/bin/zsh
# A bounded synthetic feasibility test. Never changes the installed app or
# reads its credentials. Supply the SHA-1 identity for the probe's signing team.
set -euo pipefail
repository_root=${0:A:h:h}
source "$repository_root/scripts/workspace-paths.sh"
signing_identity=${AURELIA_SIGNING_IDENTITY:-}
if [[ -z "$signing_identity" ]]; then
  print -u2 "Set AURELIA_SIGNING_IDENTITY to the matching Apple Development identity."
  exit 2
fi
mkdir -p "$other_root/Logs" "$HOME/Library/Caches/Aurelia/TestRuns"
probe_root=$(mktemp -d "$HOME/Library/Caches/Aurelia/TestRuns/Profileless-Probe.XXXXXX")
candidate="$probe_root/ProfilelessProbe.app"
log="$other_root/Logs/Profileless-Signing-${probe_root:t}.log"
probe_pid=''
cleanup() {
  if [[ -n "$probe_pid" ]] && kill -0 "$probe_pid" 2>/dev/null; then
    kill -TERM "$probe_pid" 2>/dev/null || true
  fi
  if [[ "$probe_root" == "$HOME/Library/Caches/Aurelia/TestRuns/Profileless-Probe."* ]]; then
    find "$probe_root" -depth -delete
  fi
}
trap cleanup EXIT
mkdir -p "$candidate/Contents/MacOS"
ditto "$repository_root/tools/macos/ProfilelessProbe-Info.plist" "$candidate/Contents/Info.plist"
DEVELOPER_DIR="$developer_dir" xcrun swiftc -warnings-as-errors \
  "$repository_root/tools/macos/ProfilelessSigningProbe.swift" \
  -o "$candidate/Contents/MacOS/ProfilelessProbe"
codesign --force --sign "$signing_identity" --options runtime --timestamp=none \
  --entitlements "$repository_root/tools/macos/ProfilelessProbe.entitlements" "$candidate"
codesign --verify --strict "$candidate"
[[ ! -e "$candidate/Contents/embedded.provisionprofile" ]] || exit 1
set +e
"$candidate/Contents/MacOS/ProfilelessProbe" >"$log" 2>&1 &
probe_pid=$!
for attempt in {1..100}; do
  kill -0 "$probe_pid" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$probe_pid" 2>/dev/null; then
  kill -TERM "$probe_pid" 2>/dev/null
  print "Probe timed out; no protection bypass was attempted." >>"$log"
fi
wait "$probe_pid"
result=$?
probe_pid=''
set -e
print "Probe exit status: $result" >>"$log"
print "Profileless signing feasibility log: $log"
exit "$result"
