#!/bin/zsh
# Tests a small synthetic probe, not a re-signed copy of Aurelia or its data.
set -euo pipefail
repository_root=${0:A:h:h}
source "$repository_root/scripts/workspace-paths.sh"
mkdir -p "$other_root/Logs" "$HOME/Library/Caches/Aurelia/TestRuns"
probe_root=$(mktemp -d "$HOME/Library/Caches/Aurelia/TestRuns/Distribution-Probe.XXXXXX")
log="$other_root/Logs/Distribution-Entitlements-${probe_root:t}.log"
trap '[[ "$probe_root" == "$HOME/Library/Caches/Aurelia/TestRuns/Distribution-Probe."* ]] && find "$probe_root" -depth -delete' EXIT
DEVELOPER_DIR="$developer_dir" xcrun swiftc -warnings-as-errors \
  "$repository_root/tools/macos/DistributionEntitlementProbe.swift" \
  -o "$probe_root/DistributionProbe"
codesign --force --sign - --timestamp=none \
  --entitlements "$repository_root/tools/macos/DistributionProbe.entitlements" \
  "$probe_root/DistributionProbe"
codesign --verify --strict "$probe_root/DistributionProbe"
set +e
"$probe_root/DistributionProbe" >"$log" 2>&1 &
probe_pid=$!
for attempt in {1..100}; do
  kill -0 "$probe_pid" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$probe_pid" 2>/dev/null; then
  kill -TERM "$probe_pid" 2>/dev/null
  echo "Probe timed out; no permission or container bypass was attempted." >>"$log"
fi
wait "$probe_pid"
result=$?
set -e
echo "Probe exit status: $result" >>"$log"
echo "Bounded entitlement feasibility log: $log"
# A denial is useful feasibility evidence, not a test failure or proof that a
# different free packaging architecture cannot work. Never claim a launch pass.
