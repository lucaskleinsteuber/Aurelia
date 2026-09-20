#!/bin/zsh

set -euo pipefail

readonly confirmation="--confirm-clean-test-install"
readonly bundle_id="com.lucas.aurelia.media"
readonly app_name="Aurelia"
readonly server_host_process="AureliaServerHost"
readonly server_process="Aurelia.Server"
readonly current_keychain_service="com.lucas.aurelia.media.connection.v1"
readonly legacy_keychain_service="com.lucas.aureliahome.connection.v2"

if [[ "${1:-}" != "$confirmation" || $# -ne 1 ]]; then
  print -u2 "Usage: $0 $confirmation"
  print -u2 "This permanently resets Aurelia's local test setup, but never media files."
  exit 64
fi

readonly current_user="$(/usr/bin/id -un)"
readonly user_home="$(/usr/bin/dscl . -read "/Users/$current_user" NFSHomeDirectory | /usr/bin/awk '{print $2}')"

if [[ -z "$user_home" || "$user_home" == "/" || ! -d "$user_home/Library" ]]; then
  print -u2 "Refusing to reset because the current user's Library could not be resolved safely."
  exit 65
fi

readonly current_server_data="$user_home/Library/Application Support/Aurelia Server"
readonly legacy_server_data="$user_home/Library/Application Support/Aurelia Home Server"
readonly server_logs="$user_home/Library/Logs/Aurelia Server"
readonly preferences="$user_home/Library/Preferences/$bundle_id.plist"

safe_remove() {
  local target="$1"
  case "$target" in
    "$current_server_data"|"$legacy_server_data"|"$server_logs"|"$preferences") ;;
    *)
      print -u2 "Refusing unexpected reset target: $target"
      exit 66
      ;;
  esac

  if [[ -L "$target" ]]; then
    print -u2 "Refusing symbolic-link reset target: $target"
    exit 67
  fi
  if [[ ! -e "$target" ]]; then
    print "Already clean: $target"
    return
  fi

  /usr/bin/find -x "$target" -depth -delete
  print "Removed Aurelia test state: $target"
}

if /usr/bin/pgrep -x "$app_name" >/dev/null 2>&1; then
  /usr/bin/osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
fi

for _ in {1..20}; do
  if ! /usr/bin/pgrep -x "$app_name" >/dev/null 2>&1 \
    && ! /usr/bin/pgrep -x "$server_host_process" >/dev/null 2>&1 \
    && ! /usr/bin/pgrep -x "$server_process" >/dev/null 2>&1; then
    break
  fi
  /bin/sleep 0.25
done

for process_name in "$app_name" "$server_host_process" "$server_process"; do
  /usr/bin/pkill -TERM -x "$process_name" >/dev/null 2>&1 || true
done

for _ in {1..20}; do
  if ! /usr/bin/pgrep -x "$app_name" >/dev/null 2>&1 \
    && ! /usr/bin/pgrep -x "$server_host_process" >/dev/null 2>&1 \
    && ! /usr/bin/pgrep -x "$server_process" >/dev/null 2>&1; then
    break
  fi
  /bin/sleep 0.25
done

if /usr/bin/pgrep -x "$app_name" >/dev/null 2>&1 \
  || /usr/bin/pgrep -x "$server_host_process" >/dev/null 2>&1 \
  || /usr/bin/pgrep -x "$server_process" >/dev/null 2>&1; then
  print -u2 "Aurelia processes are still running; no local state was removed."
  exit 68
fi

/usr/bin/defaults delete "$bundle_id" >/dev/null 2>&1 || true
print "Reset Aurelia sandbox preferences through macOS preferences services."

for service in "$current_keychain_service" "$legacy_keychain_service"; do
  if /usr/bin/security delete-generic-password -s "$service" -a active-server >/dev/null 2>&1; then
    print "Removed Aurelia connection profile: $service"
  else
    print "Already clean: keychain service $service"
  fi
done

safe_remove "$current_server_data"
safe_remove "$legacy_server_data"
safe_remove "$server_logs"
safe_remove "$preferences"

print "Aurelia is ready for a clean first-run test. macOS-managed container shells were preserved."
print "User media and Aurelia Classic were not touched."
