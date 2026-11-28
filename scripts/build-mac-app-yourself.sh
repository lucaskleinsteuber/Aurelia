#!/bin/zsh
# Builds Tarven for Mac on this Mac with your own free Apple ID, step by step, for people who have
# never built an app. docs/BUILD_MAC_APP.md explains every step and what to do when one fails.
#
#   zsh scripts/build-mac-app-yourself.sh
#
# It checks macOS and Xcode, installs the .NET SDK into this folder (Local/Package Cache) when it
# is missing, offers to install cmake and ninja with Homebrew, finds your Apple Development
# certificate and its team, and builds the app for this Mac's processor. The app is signed for
# your own Macs without a provisioning profile, so it does not expire after seven days; your
# certificate is valid for a year. At the end it offers to copy Tarven to Applications.
set -euo pipefail
repository_root=${0:A:h:h}
source "$repository_root/scripts/workspace-paths.sh"

step() { print; print -P "%B==> $*%b"; }
stop() { print; print -P "%F{red}%BStopped:%b%f $1"; [[ -n "${2:-}" ]] && print "$2"; exit 1; }
ask() { local answer; read -r "answer?$1 [y/N] " || true; [[ "$answer" == [yYjJ]* ]]; }

step "Checking macOS"
macos_major=$(sw_vers -productVersion | cut -d. -f1)
(( macos_major >= 26 )) || stop "Tarven needs macOS 26 or newer; this Mac has $(sw_vers -productVersion)." \
  "Update macOS in System Settings › General › Software Update."
print "macOS $(sw_vers -productVersion) – fine."

step "Checking Xcode"
developer=$(xcode-select -p 2>/dev/null || true)
[[ "$developer" == *Xcode*.app/* ]] || stop "Xcode is not installed or not selected." \
  "Install Xcode from the App Store, open it once, then run: sudo xcode-select -s /Applications/Xcode.app"
xcode_major=$(xcodebuild -version | sed -n 's/^Xcode \([0-9]*\).*/\1/p')
(( xcode_major >= 26 )) || stop "Tarven needs Xcode 26 or newer; this is Xcode $xcode_major." \
  "Update Xcode in the App Store."
xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1 || stop "Xcode has not finished its first start." \
  "Open Xcode once and let it install its components, or run: sudo xcodebuild -runFirstLaunch"
print "$(xcodebuild -version | head -1) – fine."

step "Checking cmake and ninja (needed for speech recognition)"
missing=()
for tool in cmake ninja; do command -v $tool >/dev/null 2>&1 || missing+=($tool); done
if (( ${#missing} )); then
  command -v brew >/dev/null 2>&1 || stop "${missing[*]} missing, and Homebrew is not installed." \
    "Install Homebrew as shown on https://brew.sh, open a new Terminal window and run this script again."
  ask "Install ${missing[*]} with Homebrew now?" || stop "${missing[*]} are needed." "Install them with: brew install ${missing[*]}"
  brew install "${missing[@]}"
fi
print "cmake and ninja – fine."

step "Checking the .NET SDK (builds the server inside the app)"
wanted_sdk=$(sed -n 's/.*"version": *"\([0-9.]*\)".*/\1/p' "$repository_root/global.json")
sdk_band=${wanted_sdk%??}
has_sdk() { [[ -x "$1" ]] && "$1" --list-sdks 2>/dev/null | grep -q "^$sdk_band"; }
local_dotnet="$other_root/Package Cache/dotnet/dotnet"
if has_sdk "$(command -v dotnet 2>/dev/null || true)"; then
  DOTNET_BIN=$(command -v dotnet)
elif has_sdk "$local_dotnet"; then
  DOTNET_BIN=$local_dotnet
else
  print "Downloading the .NET SDK $wanted_sdk from Microsoft into Local/Package Cache (about 250 MB)…"
  mkdir -p "$other_root/Package Cache"
  curl --fail --location --silent --show-error https://dot.net/v1/dotnet-install.sh \
    -o "$other_root/Package Cache/dotnet-install.sh"
  bash "$other_root/Package Cache/dotnet-install.sh" --version "$wanted_sdk" \
    --install-dir "$other_root/Package Cache/dotnet" --no-path
  DOTNET_BIN=$local_dotnet
  has_sdk "$DOTNET_BIN" || stop "The .NET SDK could not be installed." "Check the internet connection and try again."
fi
export DOTNET_BIN
print ".NET SDK $("$DOTNET_BIN" --version) – fine."

step "Finding your Apple Development certificate"
identities=$(security find-identity -v -p codesigning | grep 'Apple Development:' || true)
[[ -n "$identities" ]] || stop "No Apple Development certificate was found." \
  "In Xcode open Settings › Accounts, add your Apple ID, click Manage Certificates…, then + › Apple Development. Run this script again."
signing_identity=${TARVEN_SIGNING_IDENTITY:-$(print -r -- "$identities" | head -1 | awk '{print $2}')}
print -r -- "$(print -r -- "$identities" | grep "$signing_identity" | sed 's/^ *[0-9]*) [0-9A-F]* //')"
# The team ID is part of the certificate; signing a throwaway copy of a small program reveals it.
probe_root=$(mktemp -d)
trap 'rm -rf "$probe_root"' EXIT
cp /usr/bin/true "$probe_root/probe"
codesign --force --sign "$signing_identity" "$probe_root/probe" 2>/dev/null \
  || stop "macOS did not let this certificate sign." \
    "If a window asked for your login password, run the script again and choose Always Allow."
team=$(codesign --display --verbose=4 "$probe_root/probe" 2>&1 | sed -n 's/^TeamIdentifier=//p')
[[ "$team" =~ '^[A-Z0-9]{10}$' ]] || stop "The certificate has no team ID." \
  "Sign in with your Apple ID in Xcode › Settings › Accounts and create the certificate there."
print "Team $team – fine."

case "$(uname -m)" in
  arm64) arch=arm64; label="Apple silicon" ;;
  *) arch=x64; label="Intel" ;;
esac
step "Building Tarven for this Mac ($label). This takes 15 to 40 minutes the first time."
TARVEN_TEAM_ID=$team TARVEN_SIGNING_IDENTITY=$signing_identity \
  TARVEN_DISTRIBUTION=profileless-development TARVEN_MAC_ARCH=$arch \
  zsh "$repository_root/scripts/build-macos-release.sh"

build_number=$(sed -n 's/^CURRENT_PROJECT_VERSION = \([0-9][0-9]*\)$/\1/p' \
  "$repository_root/clients/macos/Configuration/BuildNumber.xcconfig")
app="$other_root/Build/Build $build_number"
[[ "$arch" == x64 ]] && app="$app x64"
app="$app/Tarven.app"
[[ -d "$app" ]] || stop "The build finished, but Tarven.app is not where it should be: $app"

step "Done"
print "Tarven is built: $app"
if pgrep -x Tarven >/dev/null 2>&1 \
  || pgrep -x TarvenServerHost >/dev/null 2>&1 \
  || pgrep -f '^/Applications/Tarven\.app/Contents/' >/dev/null 2>&1; then
  print "Tarven or its background server is running."
  print "Quit Tarven and stop its background server (in Settings › Power or from the menu bar icon), then drag the new Tarven.app into Applications (replace the old one)."
  open -R "$app"
elif ask "Copy Tarven to Applications now (replacing an older Tarven there)?"; then
  rm -rf "/Applications/Tarven.app.new"
  ditto "$app" "/Applications/Tarven.app.new"
  rm -rf "/Applications/Tarven.app"
  mv "/Applications/Tarven.app.new" "/Applications/Tarven.app"
  print "Tarven is in Applications. Open it from there; your library and settings stay as they were."
else
  print "Drag Tarven.app from the window that opens into Applications."
  open -R "$app"
fi
print "Build it again the same way to update Tarven, and before your certificate expires in a year."
