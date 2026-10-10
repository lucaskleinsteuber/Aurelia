#!/bin/zsh
# Source-only signing-policy checks. No signing identities or running apps needed.
set -euo pipefail
repository_root=${0:A:h:h}
test_parent="$HOME/Library/Caches/Aurelia/TestRuns"
mkdir -p "$test_parent"
task_test_root=$(mktemp -d "$test_parent/Profileless-Policy.XXXXXX")
trap '[[ "$task_test_root" == "$test_parent/Profileless-Policy."* ]] && find "$task_test_root" -depth -delete' EXIT
source_entitlements="$repository_root/clients/macos/Configuration/Aurelia.entitlements"
helper_entitlements="$repository_root/clients/macos/Configuration/AureliaServerHost.entitlements"
generated="$task_test_root/profileless.entitlements"
fixture="$task_test_root/invalid.entitlements"
validator="$repository_root/scripts/verify-profileless-macos-entitlements.sh"
/usr/bin/ditto "$source_entitlements" "$generated"
/usr/libexec/PlistBuddy -c 'Delete :keychain-access-groups' "$generated"
checks=0
pass() {
  print "PASS: $1"
  checks=$((checks + 1))
}
reject() {
  if /bin/zsh "$validator" "$1" "$helper_entitlements" >"$task_test_root/result" 2>&1; then
    print -u2 "FAIL: signing policy accepted $2."
    exit 1
  fi
  pass "rejects $2"
}
/bin/zsh "$validator" "$generated" "$helper_entitlements"
pass "accepts the profileless shape with existing sandbox and permissions"
reject "$source_entitlements" "restricted Keychain declarations"
for permission in com.apple.security.app-sandbox \
  com.apple.security.files.user-selected.read-write com.apple.security.network.client \
  com.apple.security.network.server com.apple.security.cs.disable-library-validation; do
  /usr/bin/ditto "$generated" "$fixture"
  /usr/libexec/PlistBuddy -c "Set :$permission false" "$fixture"
  reject "$fixture" "disabled $permission"
done
/usr/bin/ditto "$generated" "$fixture"
/usr/libexec/PlistBuddy -c 'Set :com.apple.security.application-groups:0 group.invalid.fixture' "$fixture"
reject "$fixture" "a changed App Group"
/usr/bin/ditto "$generated" "$fixture"
/usr/libexec/PlistBuddy -c 'Add :com.apple.application-identifier string test.fixture' "$fixture"
reject "$fixture" "a profile-dependent application identifier"
for identity in '' malformed; do
  if /bin/zsh "$repository_root/scripts/verify-profileless-macos-identity.sh" \
    "$identity" B5N7JVK37J "$task_test_root/unused-verifier" >"$task_test_root/result" 2>&1; then
    print -u2 "FAIL: signing policy accepted an invalid identity."
    exit 1
  fi
  pass "rejects missing or malformed identity before signing"
done
print "Profileless signing policy passed $checks checks."
