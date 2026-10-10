#!/bin/zsh
# A small allowlist deliberately rejects newly added restricted entitlements.
# Do not use a generic com.apple.* prefix as a substitute for profile authorization.
set -euo pipefail
application_entitlements=${1:?Provide the generated application entitlements.}
helper_entitlements=${2:?Provide the helper entitlements.}
for entitlements in "$application_entitlements" "$helper_entitlements"; do
  /usr/bin/plutil -lint "$entitlements" >/dev/null
  entitlement_json=$(/usr/bin/plutil -convert json -o - "$entitlements")
  if ! print -r -- "$entitlement_json" | /usr/bin/ruby -rjson -e '
      allowed = %w[com.apple.security.app-sandbox com.apple.security.application-groups
        com.apple.security.cs.disable-library-validation
        com.apple.security.files.user-selected.read-write
        com.apple.security.network.client com.apple.security.network.server]
      value = JSON.parse(STDIN.read)
      abort "Unsupported entitlement in the profileless local mode." unless (value.keys - allowed).empty?
      abort "The existing team-prefixed App Group must be retained." unless
        value["com.apple.security.application-groups"] == ["B5N7JVK37J.com.lucas.aurelia.media.host"]
    '; then
    exit 1
  fi
done
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$application_entitlements")" == true ]] || {
  print -u2 "Profileless local development must preserve the application sandbox."
  exit 1
}
for entitlement in com.apple.security.files.user-selected.read-write \
  com.apple.security.network.client com.apple.security.network.server \
  com.apple.security.cs.disable-library-validation; do
  [[ "$(/usr/libexec/PlistBuddy -c "Print :$entitlement" "$application_entitlements")" == true ]] || {
    print -u2 "The application's existing $entitlement permission must be retained."
    exit 1
  }
done
