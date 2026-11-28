#!/bin/zsh
# Source-only signing-policy checks. No signing identities or running apps needed.
set -euo pipefail
repository_root=${0:A:h:h}
test_parent="$HOME/Library/Caches/Tarven/TestRuns"
mkdir -p "$test_parent"
task_test_root=$(mktemp -d "$test_parent/Profileless-Policy.XXXXXX")
trap '[[ "$task_test_root" == "$test_parent/Profileless-Policy."* ]] && find "$task_test_root" -depth -delete' EXIT
source_entitlements="$repository_root/clients/macos/Configuration/Tarven.entitlements"
helper_entitlements="$repository_root/clients/macos/Configuration/TarvenServerHost.entitlements"
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
test_app_group="B5N7JVK37J.org.tarven.mac.test.host"
test_app_entitlements="$task_test_root/test-app.entitlements"
test_helper_entitlements="$task_test_root/test-helper.entitlements"
/usr/bin/ditto "$source_entitlements" "$test_app_entitlements"
/usr/bin/ditto "$helper_entitlements" "$test_helper_entitlements"
/usr/libexec/PlistBuddy -c "Set :com.apple.security.application-groups:0 $test_app_group" "$test_app_entitlements"
/usr/libexec/PlistBuddy -c "Set :com.apple.security.application-groups:0 $test_app_group" "$test_helper_entitlements"
/usr/libexec/PlistBuddy -c 'Delete :keychain-access-groups' "$test_app_entitlements"
/usr/libexec/PlistBuddy -c 'Add :keychain-access-groups array' "$test_app_entitlements"
/usr/libexec/PlistBuddy -c 'Add :keychain-access-groups:0 string B5N7JVK37J.org.tarven.mac.test' "$test_app_entitlements"
test_keychain_json=$(/usr/bin/plutil -convert json -o - "$test_app_entitlements")
if ! print -r -- "$test_keychain_json" | /usr/bin/ruby -rjson -e '
    value = JSON.parse(STDIN.read)
    abort "Unexpected test-edition keychain groups." unless
      value["keychain-access-groups"] == ["B5N7JVK37J.org.tarven.mac.test"]
  '; then
  print -u2 "FAIL: test-edition keychain access group isolation check failed."
  exit 1
fi
pass "isolates test-edition keychain access groups away from production"
if TARVEN_EXPECTED_APP_GROUP="$test_app_group" /bin/zsh "$validator" \
  "$test_app_entitlements" "$test_helper_entitlements" >"$task_test_root/result" 2>&1; then
  print -u2 "FAIL: signing policy accepted test-edition profileless entitlements with keychain-access-groups."
  exit 1
fi
pass "rejects test-edition profileless entitlements with restricted Keychain declarations"
/usr/libexec/PlistBuddy -c 'Delete :keychain-access-groups' "$test_app_entitlements"
TARVEN_EXPECTED_APP_GROUP="$test_app_group" /bin/zsh "$validator" \
  "$test_app_entitlements" "$test_helper_entitlements"
pass "accepts test-edition profileless entitlements with isolated App Group and no Keychain groups"
print "Profileless signing policy passed $checks checks."
