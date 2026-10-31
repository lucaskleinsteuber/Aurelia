#!/bin/zsh
# Keeps locally signed Aurelia apps running past their 7-day provisioning profiles.
#
# A free Apple account issues development profiles that expire after 7 days; an app whose
# profile expired no longer launches. This script asks Apple for fresh profiles and re-signs the
# installed Mac app, the Apple TV app and the iPhone app with them. The app versions stay the same: the existing
# bundles are re-signed, nothing is rebuilt from newer source.
#
#   zsh scripts/refresh-signing.sh --install      set up the state folder and the daily job
#   zsh scripts/refresh-signing.sh --adopt-tv     hand the Apple TV build just installed to the job
#                                                 (its build folder is deleted afterwards)
#   zsh scripts/refresh-signing.sh --adopt-iphone the same for the iPhone build just installed
#   zsh scripts/refresh-signing.sh [--force]      refresh what expires within 3 days (or all)
#   zsh scripts/refresh-signing.sh --force iphone refresh one app now: mac, tv or iphone
#   zsh scripts/refresh-signing.sh --uninstall    remove the job (keeps the state folder)
#
# Background jobs may not read ~/Documents, so the job works from its own state folder in
# ~/Library/Application Support with a copy of this script, a small checkout used only to
# request profiles, and copies of the installed Apple TV and iPhone apps. Run --install and the
# --adopt options interactively from the repository.
set -euo pipefail

script_path=${0:A}
state="$HOME/Library/Application Support/Aurelia Signing Refresh"
log_file="$HOME/Library/Logs/Aurelia Signing Refresh.log"
label=local.aurelia.signing-refresh
agent="$HOME/Library/LaunchAgents/$label.plist"
profiles="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
mac_app=/Applications/Aurelia.app
mac_bundle=com.lucas.aurelia.media
tv_bundle=com.lucas.aurelia.tvos
iphone_bundle=com.lucas.aurelia.ios
threshold_seconds=$((3 * 24 * 60 * 60))
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p)}

# Messages go to stderr and the log; stdout carries function results.
log() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$log_file" >&2; }
notify() {
  /usr/bin/osascript -e "display notification \"$1\" with title \"Aurelia\"" >/dev/null 2>&1 || true
}

# ExpirationDate of a profile file, as seconds since 1970.
profile_expiry() {
  local date
  date=$(security cms -D -i "$1" 2>/dev/null | plutil -extract ExpirationDate raw -o - - 2>/dev/null) \
    || return 1
  date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$date" +%s
}

profile_name() {
  security cms -D -i "$1" 2>/dev/null | plutil -extract Name raw -o - - 2>/dev/null
}

# The cached profiles Xcode made for one bundle and platform ("Mac", "tvOS" or "iOS").
cached_profiles() {
  local platform=$1 bundle=$2 file
  [[ -d "$profiles" ]] || return 0
  for file in "$profiles"/*(N.); do
    [[ "$(profile_name "$file")" == "$platform Team Provisioning Profile: $bundle" ]] \
      && print -r -- "$file"
  done
  return 0
}

# Makes Xcode request a fresh profile: the cached one is set aside, the project's signing step
# runs, and the build is stopped once the new profile is there. The build itself does not
# matter and may fail; signing preparation comes before compiling.
request_profile() {
  local platform=$1 bundle=$2 project=$3 scheme=$4 destination=$5
  local retired="$state/Retired Profiles" started new="" pid waited=0 old
  mkdir -p "$retired"
  local -a previous
  previous=("${(@f)$(cached_profiles "$platform" "$bundle")}")
  previous=(${previous:#})
  for old in $previous; do mv "$old" "$retired/"; done
  started=$(date +%s)
  xcodebuild -project "$state/Checkout/$project" -scheme "$scheme" -configuration Debug \
    -destination "$destination" -destination-timeout 60 \
    -derivedDataPath "$state/DerivedData/$platform" \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration build \
    >>"$log_file" 2>&1 &
  pid=$!
  while (( waited < 600 )); do
    new=$(cached_profiles "$platform" "$bundle" | head -1)
    [[ -n "$new" ]] && break
    kill -0 $pid 2>/dev/null || { new=$(cached_profiles "$platform" "$bundle" | head -1); break; }
    sleep 3
    waited=$((waited + 3))
  done
  pkill -TERM -P $pid 2>/dev/null || true
  kill -TERM $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true
  if [[ -z "$new" ]]; then
    # Put the old profiles back so normal builds keep working.
    for old in $previous; do mv "$retired/${old:t}" "$profiles/" 2>/dev/null || true; done
    log "$platform: Apple issued no new profile (started $(date -r $started '+%H:%M:%S'))."
    return 1
  fi
  print -r -- "$new"
}

sha1_of_der() {
  openssl x509 -inform DER -noout -fingerprint -sha1 | sed -E 's/^[^=]*=//; s/://g' \
    | tr '[:lower:]' '[:upper:]'
}

# The SHA-1 of a certificate the profile authorizes and the keychain holds. The certificate
# that already signs the app comes first, so its keychain access stays exactly as it was.
signing_identity() {
  local profile=$1 app=$2 plist current="" index=0 fingerprint
  local -a allowed
  plist=$(mktemp) && security cms -D -i "$profile" >"$plist" 2>/dev/null || return 1
  while fingerprint=$(plutil -extract "DeveloperCertificates.$index" raw -o - "$plist" 2>/dev/null \
    | base64 -D | sha1_of_der) && [[ -n "$fingerprint" ]]; do
    allowed+=("$fingerprint")
    index=$((index + 1))
  done
  rm -f "$plist"
  local extracted=$(mktemp -d)
  if codesign -d --extract-certificates="$extracted/cert" "$app" 2>/dev/null \
    && [[ -r "$extracted/cert0" ]]; then
    current=$(sha1_of_der <"$extracted/cert0")
  fi
  rm -rf "$extracted"
  for fingerprint in ${current:+$current} $allowed; do
    (( ${allowed[(Ie)$fingerprint]} )) || continue
    security find-identity -v -p codesigning \
      | awk -v id="$fingerprint" '$2 == id { found = 1 } END { exit !found }' || continue
    print -r -- "$fingerprint"
    return 0
  done
  return 1
}

# Embeds the profile and re-signs only the outer bundle. Nested frameworks and helpers keep
# their own valid signatures; identifier, entitlements and hardened runtime are preserved.
resign() {
  local app=$1 profile=$2 embedded=$3 identity
  identity=$(signing_identity "$profile" "$app") || {
    log "No signing identity for $profile."
    return 1
  }
  cp "$profile" "$app/$embedded" || return 1
  codesign --force --sign "$identity" \
    --preserve-metadata=identifier,entitlements,requirements,flags,runtime \
    --timestamp=none "$app" || { log "codesign failed for $app."; return 1; }
  codesign --verify --deep --strict "$app" || { log "The re-signed $app does not verify."; return 1; }
}

needs_refresh() {
  local expiry=$1
  [[ -n "${force:-}" ]] && return 0
  (( expiry - $(date +%s) < threshold_seconds ))
}

bundle_version() {
  print -r -- "$(plutil -extract CFBundleShortVersionString raw "$1/$2") ($(plutil -extract CFBundleVersion raw "$1/$2"))"
}

refresh_mac() {
  [[ -d "$mac_app" ]] || { log "Mac: no app installed."; return 0; }
  local expiry
  expiry=$(profile_expiry "$mac_app/Contents/embedded.provisionprofile") || {
    log "Mac: the installed app has no readable profile; nothing to do."
    return 0
  }
  needs_refresh "$expiry" || { log "Mac: valid until $(date -r $expiry '+%d.%m. %H:%M')."; return 0; }
  if pgrep -f "$mac_app/Contents/" >/dev/null; then
    log "Mac: Aurelia is open; trying again later."
    if (( expiry - $(date +%s) < 24 * 60 * 60 )); then
      notify "Quit Aurelia once so it can be re-signed; it stops opening on $(date -r $expiry '+%d.%m. at %H:%M')."
    fi
    return 0
  fi
  local profile stage="$state/Stage/Aurelia.app" before after
  profile=$(request_profile Mac "$mac_bundle" clients/macos/Aurelia.xcodeproj Aurelia \
    'platform=macOS') || return 1
  before=$(bundle_version "$mac_app" Contents/Info.plist)
  rm -rf "$state/Stage" && mkdir -p "$state/Stage" && ditto "$mac_app" "$stage" || return 1
  resign "$stage" "$profile" Contents/embedded.provisionprofile || return 1
  [[ "$(bundle_version "$stage" Contents/Info.plist)" == "$before" ]] || return 1
  if pgrep -f "$mac_app/Contents/" >/dev/null; then
    log "Mac: Aurelia was opened meanwhile; trying again later."
    return 0
  fi
  rm -rf "$mac_app" && ditto "$stage" "$mac_app" || { log "Mac: copying the app failed."; return 1; }
  rm -rf "$state/Stage"
  codesign --verify --deep --strict "$mac_app" || { log "Mac: installed app does not verify."; return 1; }
  after=$(bundle_version "$mac_app" Contents/Info.plist)
  [[ "$before" == "$after" ]] || { log "Mac: version changed from $before to $after."; return 1; }
  expiry=$(profile_expiry "$mac_app/Contents/embedded.provisionprofile")
  log "Mac: $after re-signed, valid until $(date -r $expiry '+%d.%m. %H:%M')."
  notify "Mac app re-signed, valid until $(date -r $expiry '+%d.%m.')."
}

# A paired device app: "tv" for the Apple TV, "iphone" for the iPhone. Sets the globals the
# functions below use.
device_kind() {
  case $1 in
    tv)
      name="Apple TV" folder=tvOS bundle=$tv_bundle platform=tvOS
      project=clients/tvos/AureliaTV.xcodeproj scheme=AureliaTV products=Release-appletvos
      device_match="Apple TV" device_variable=AURELIA_TV_DEVICE adopt_option=--adopt-tv
      ;;
    iphone)
      name=iPhone folder=iOS bundle=$iphone_bundle platform=iOS
      project=clients/ios/AureliaIOS.xcodeproj scheme=AureliaIOS products=Release-iphoneos
      device_match=iPhone device_variable=AURELIA_IPHONE_DEVICE adopt_option=--adopt-iphone
      ;;
  esac
}

device_installed_version() {
  local device=$1 out attempt
  for attempt in 1 2 3; do
    out=$(xcrun devicectl device info apps --device "$device" --bundle-id "$bundle" 2>&1) || true
    if print -r -- "$out" | grep -q "$bundle"; then
      print -r -- "$out" | awk -v id="$bundle" '$2 == id { print $3 " (" $4 ")" }'
      return 0
    fi
  done
  return 1
}

refresh_device() {
  local name folder bundle platform project scheme products device_match device_variable
  local adopt_option
  device_kind "$1"
  local app="$state/$folder/Aurelia.app" device expiry installed adopted profile stage attempt
  [[ -d "$app" && -r "$state/$folder/device" ]] || {
    log "$name: no build adopted yet (run $adopt_option)."
    return 0
  }
  device=$(<"$state/$folder/device")
  expiry=$(profile_expiry "$app/embedded.mobileprovision")
  needs_refresh "$expiry" || {
    log "$name: valid until $(date -r $expiry '+%d.%m. %H:%M')."
    return 0
  }
  installed=$(device_installed_version "$device") || {
    log "$name: not reachable; trying again later."
    if (( expiry - $(date +%s) < 24 * 60 * 60 )); then
      notify "Unlock the $name on this network so Aurelia can be re-signed; it stops opening on $(date -r $expiry '+%d.%m. at %H:%M')."
    fi
    return 0
  }
  adopted=$(bundle_version "$app" Info.plist)
  if [[ "$installed" != "$adopted" ]]; then
    log "$name: $installed is installed but $adopted was adopted; run $adopt_option."
    notify "$name app: run refresh-signing.sh $adopt_option once."
    return 1
  fi
  profile=$(request_profile "$platform" "$bundle" "$project" "$scheme" "id=$device") || return 1
  stage="$state/Stage/Aurelia.app"
  rm -rf "$state/Stage" && mkdir -p "$state/Stage" && ditto "$app" "$stage" || return 1
  resign "$stage" "$profile" embedded.mobileprovision || return 1
  for attempt in 1 2 3; do
    if xcrun devicectl device install app --device "$device" "$stage" >>"$log_file" 2>&1; then
      break
    fi
    (( attempt == 3 )) && { log "$name: installing failed."; return 1; }
    sleep 5
  done
  installed=$(device_installed_version "$device") || installed=unknown
  [[ "$installed" == "$adopted" ]] || { log "$name: now reports $installed."; return 1; }
  rm -rf "$app" && mv "$stage" "$app" && rm -rf "$state/Stage"
  expiry=$(profile_expiry "$app/embedded.mobileprovision")
  log "$name: $installed re-signed, valid until $(date -r $expiry '+%d.%m. %H:%M')."
  notify "$name app re-signed, valid until $(date -r $expiry '+%d.%m.')."
}

repository() {
  local root=${script_path:h:h}
  [[ -d "$root/.git" && -f "$root/clients/tvos/AureliaTV.xcodeproj/project.pbxproj" ]] || {
    print -u2 "Run this from the Aurelia repository."
    exit 1
  }
  print -r -- "$root"
}

update_checkout() {
  local root=$1
  if [[ -d "$state/Checkout/.git" ]]; then
    git -C "$state/Checkout" fetch --quiet --depth 1 origin main
    git -C "$state/Checkout" reset --quiet --hard FETCH_HEAD
  else
    git clone --quiet --depth 1 --branch main "file://$root" "$state/Checkout"
  fi
  cp "$root/scripts/refresh-signing.sh" "$state/refresh-signing.sh"
}

# Copies the device build that is installed now, found by its version in the build folder.
adopt_device() {
  local name folder bundle platform project scheme products device_match device_variable
  local adopt_option
  device_kind "$2"
  local root=$1 device=${(P)device_variable:-} installed version build candidate
  local repository_root=$root
  source "$root/scripts/workspace-paths.sh"
  if [[ -z "$device" && -r "$state/$folder/device" ]]; then device=$(<"$state/$folder/device"); fi
  if [[ -z "$device" ]]; then
    # "Apple TV 4K (27.2) (00008110-…)": the identifier is the last parenthesized part.
    device=$(xcrun xctrace list devices 2>/dev/null | sed -n '/^== Devices ==/,/^== /p' \
      | grep "$device_match" | grep -v Simulator | head -1 \
      | sed -E 's/.*\(([^()]*)\)[[:space:]]*$/\1/')
  fi
  [[ -n "$device" ]] || { print -u2 "No $name found; set $device_variable."; return 1; }
  installed=$(device_installed_version "$device") || {
    print -u2 "The $name is not reachable."
    return 1
  }
  version=${installed%% *}
  build=${${installed##*\(}%\)}
  candidate="$other_root/Build/$folder/$version-$build/DerivedData/Build/Products/$products/Aurelia.app"
  [[ -d "$candidate" ]] || { print -u2 "No build for $installed at $candidate."; return 1; }
  [[ "$(bundle_version "$candidate" Info.plist)" == "$installed" ]] || {
    print -u2 "The build folder for $installed holds a different version."
    return 1
  }
  mkdir -p "$state/$folder"
  rm -rf "$state/$folder/Aurelia.app"
  ditto "$candidate" "$state/$folder/Aurelia.app"
  print -r -- "$device" >"$state/$folder/device"
  # The job's copy is the one that is kept; the build folder is not needed any more.
  rm -rf -- "$other_root/Build/$folder/$version-$build"
  log "$name: adopted $installed."
}

install_agent() {
  mkdir -p "${agent:h}"
  cat >"$agent" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array><string>/bin/zsh</string><string>$state/refresh-signing.sh</string></array>
  <key>StartCalendarInterval</key>
  <array>
    <dict><key>Hour</key><integer>4</integer><key>Minute</key><integer>30</integer></dict>
    <dict><key>Hour</key><integer>14</integer><key>Minute</key><integer>30</integer></dict>
  </array>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>LowPriorityIO</key><true/>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$agent"
}

mkdir -p "$state" "${log_file:h}"
case "${1:-}" in
  --install)
    root=$(repository)
    update_checkout "$root"
    adopt_device "$root" tv || true
    adopt_device "$root" iphone || true
    install_agent
    log "Installed: runs daily at 4:30 and 14:30, and at login."
    ;;
  --adopt-tv)
    root=$(repository)
    update_checkout "$root"
    adopt_device "$root" tv
    ;;
  --adopt-iphone)
    root=$(repository)
    update_checkout "$root"
    adopt_device "$root" iphone
    ;;
  --uninstall)
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    rm -f "$agent"
    log "Uninstalled the daily job."
    ;;
  --force | "")
    [[ "${1:-}" == --force ]] && force=1
    mkdir "$state/.lock" 2>/dev/null || { log "Another refresh is running."; exit 0; }
    trap 'rmdir "$state/.lock" 2>/dev/null || true' EXIT
    [[ -d "$state/Checkout" ]] || { log "Not set up; run --install."; exit 1; }
    only=${2:-}
    [[ -z "$only" || "$only" == (mac|tv|iphone) ]] || { print -u2 "Unknown app: $only"; exit 2; }
    failed=0
    [[ -z "$only" || "$only" == mac ]] && { refresh_mac || failed=1; }
    [[ -z "$only" || "$only" == tv ]] && { refresh_device tv || failed=1; }
    [[ -z "$only" || "$only" == iphone ]] && { refresh_device iphone || failed=1; }
    if (( failed )); then
      notify "Re-signing failed. See ~/Library/Logs/Aurelia Signing Refresh.log."
      exit 1
    fi
    ;;
  *)
    print -u2 "Usage: refresh-signing.sh [--install | --adopt-tv | --adopt-iphone | --uninstall | --force [mac|tv|iphone]]"
    exit 2
    ;;
esac
