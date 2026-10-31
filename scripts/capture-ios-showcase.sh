#!/bin/zsh
# Internal helper dispatched by capture-showcase.sh --ios-only: README screenshots of the iPhone
# and iPad app from the same invented library (scripts/make-showcase.swift). The DEBUG app shows
# it in its showcase mode in temporary simulator sessions; no server, media or personal data.
set -euo pipefail

repository_root=${0:A:h:h}
source "$repository_root/scripts/workspace-paths.sh"
/bin/sh "$repository_root/scripts/prune-workspace.sh" || true
showcase="$other_root/Showcase"
screenshots="$repository_root/docs/assets/screenshots"
run_root="$HOME/Library/Caches/Aurelia/TestRuns/ios-showcase-$(uuidgen | tr '[:upper:]' '[:lower:]')"
mkdir -p "$run_root" "$screenshots"

swift "$repository_root/scripts/make-showcase.swift" "$showcase"
# Simulator apps may not read this folder, so it is served on the loopback address only while
# the screenshots are taken, as for the Mac and Apple TV.
port=8767
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$showcase" >/dev/null 2>&1 &
server=$!
trap 'kill $server 2>/dev/null || true; rm -rf "$run_root"' EXIT

DEVELOPER_DIR="$developer_dir" xcodebuild -project "$repository_root/clients/ios/AureliaIOS.xcodeproj" \
  -scheme AureliaIOS -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$run_root/DerivedData" \
  MOBILEVLCKIT_ROOT="$repository_root/clients/ios/Dependencies" CODE_SIGNING_ALLOWED=NO \
  build >"$run_root/build.log" 2>&1 || { grep -E "error:" "$run_root/build.log" | sort -u; exit 1; }
app="$run_root/DerivedData/Build/Products/Debug-iphonesimulator/Aurelia.app"

# The newest available simulator of each kind, the same model whose screen the README shows.
device_for() {
  xcrun simctl list devices available | grep -F "    $1 (" | tail -1 \
    | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/'
}

capture() {
  local name=$1 prefix=$2; shift 2
  local device
  device=$(device_for "$name")
  [[ -n "$device" ]] || { print -u2 "No $name simulator is installed."; exit 1; }
  xcrun simctl boot "$device" 2>/dev/null || true
  xcrun simctl bootstatus "$device" -b >/dev/null
  xcrun simctl ui "$device" appearance dark
  xcrun simctl status_bar "$device" override --time 9:41 --batteryState charged \
    --batteryLevel 100 --wifiBars 3 --cellularBars 4
  xcrun simctl install "$device" "$app"
  local page
  for page in "$@"; do
    xcrun simctl terminate "$device" com.lucas.aurelia.ios 2>/dev/null || true
    SIMCTL_CHILD_AURELIA_IOS_UI_SCENARIO=showcase SIMCTL_CHILD_AURELIA_SHOWCASE_DIR="http://127.0.0.1:$port/" \
      SIMCTL_CHILD_AURELIA_IOS_SHOWCASE_PAGE="$page" \
      xcrun simctl launch "$device" com.lucas.aurelia.ios --aurelia-ui-testing >/dev/null
    # Artwork loads from local files; this leaves time for the pictures to fade in.
    sleep 6
    xcrun simctl io "$device" screenshot "$run_root/$prefix-$page.png" >/dev/null 2>&1
    sips -s format jpeg -s formatOptions 82 -Z 1600 "$run_root/$prefix-$page.png" \
      --out "$screenshots/$prefix-$page.jpg" >/dev/null
  done
  xcrun simctl terminate "$device" com.lucas.aurelia.ios 2>/dev/null || true
  xcrun simctl status_bar "$device" clear
  xcrun simctl shutdown "$device"
}

capture "iPhone 17 Pro" iphone home detail
capture "iPad Pro 13-inch (M5)" ipad home
print "iPhone and iPad screenshots in $screenshots"
