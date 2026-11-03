#!/bin/zsh
set -euo pipefail

repository_root=${0:A:h:h}
source "$repository_root/scripts/workspace-paths.sh"
# Old builds and test results are removed first; see prune-workspace.sh.
/bin/sh "$repository_root/scripts/prune-workspace.sh" || true
dotnet_bin=$DOTNET_BIN
provisioning_profile=${AURELIA_PROVISIONING_PROFILE:-}
bundle_identifier=com.lucas.aurelia.media
team_identifier=B5N7JVK37J
distribution=${AURELIA_DISTRIBUTION:-development}
timestamp_option=--timestamp=none
if [[ "$distribution" != development && "$distribution" != profileless-development && "$distribution" != developer-id ]]; then
  echo "AURELIA_DISTRIBUTION must be development, profileless-development, or developer-id." >&2
  exit 1
fi
if [[ "$distribution" == developer-id ]]; then
  if [[ -z "$provisioning_profile" || -z "${AURELIA_SIGNING_IDENTITY:-}" ]]; then
    echo "Developer ID distribution requires an explicit matching profile and signing identity." >&2
    exit 1
  fi
  timestamp_option=--timestamp
fi
build_parent="$other_root/Build"
build_number=$(sed -n 's/^CURRENT_PROJECT_VERSION = \([0-9][0-9]*\)$/\1/p' "$repository_root/clients/macos/Configuration/BuildNumber.xcconfig")
if [[ -z "$build_number" ]]; then
  echo "Unable to read the Aurelia build number." >&2
  exit 1
fi
final_root=${AURELIA_CANDIDATE_OUTPUT:-"$build_parent/Build $build_number"}
if [[ "$final_root" != "$build_parent/Build $build_number" && "$final_root" != "$build_parent/Preflight-"* ]]; then
  echo "Candidate output must be the numbered build or a fresh Preflight directory under $build_parent." >&2
  exit 1
fi
if [[ "$final_root" == "$build_parent/Preflight-"* && -e "$final_root" ]]; then
  echo "Preflight output must be a new directory." >&2
  exit 1
fi
mkdir -p "$build_parent"
stage_root=$(mktemp -d "$build_parent/.build${build_number}.XXXXXX")
derived_data="$stage_root/DerivedData"
publish_root="$stage_root/Server"
candidate="$stage_root/Aurelia.app"
profile_plist="$stage_root/provisioning-profile.plist"
release_entitlements="$stage_root/Aurelia-release.entitlements"

cleanup() {
  rm -rf -- "$stage_root"
}
trap cleanup EXIT

if [[ "$distribution" == profileless-development ]]; then
  # This is an explicitly selected local mode, never a public package. Its
  # certificate still expires; the short-lived provisioning profile is absent.
  signing_identity=${AURELIA_SIGNING_IDENTITY:-}
  /bin/zsh "$repository_root/scripts/verify-profileless-macos-identity.sh" \
    "$signing_identity" "$team_identifier" "$stage_root/Identity Verification"
  if [[ -n "$provisioning_profile" ]]; then
    echo "Profileless development must not select a provisioning profile." >&2
    exit 1
  fi
else
if [[ -z "$provisioning_profile" ]]; then
  profile_directory="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
  profile_candidates=()
  if [[ -d "$profile_directory" ]]; then
    while IFS= read -r -d '' candidate_profile; do
      profile_candidates+=("$candidate_profile")
    done < <(find "$profile_directory" -maxdepth 1 -type f \
      \( -name '*.provisionprofile' -o -name '*.mobileprovision' \) -print0)
  fi
  profile_candidates+=(/Applications/Aurelia.app/Contents/embedded.provisionprofile)
  selected_expiration=0
  for candidate_profile in "${profile_candidates[@]}"; do
    [[ -r "$candidate_profile" ]] || continue
    /usr/bin/security cms -D -i "$candidate_profile" >"$profile_plist" 2>/dev/null || continue
    candidate_app_id=$(/usr/libexec/PlistBuddy \
      -c 'Print :Entitlements:com.apple.application-identifier' "$profile_plist" 2>/dev/null || true)
    candidate_team=$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$profile_plist" 2>/dev/null || true)
    [[ "$candidate_app_id" == "$team_identifier.$bundle_identifier" \
      && "$candidate_team" == "$team_identifier" ]] || continue
    candidate_expiration=$(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$profile_plist" 2>/dev/null || true)
    candidate_epoch=$(/bin/date -j -f '%a %b %d %H:%M:%S %Z %Y' \
      "$candidate_expiration" +%s 2>/dev/null || true)
    [[ -n "$candidate_epoch" && "$candidate_epoch" -gt $(/bin/date +%s) \
      && "$candidate_epoch" -gt "$selected_expiration" ]] || continue
    candidate_fingerprint=$(/usr/bin/plutil -extract DeveloperCertificates.0 raw -o - "$profile_plist" \
      | /usr/bin/base64 -D \
      | /usr/bin/openssl x509 -inform DER -noout -fingerprint -sha1 \
      | /usr/bin/sed -E 's/^[^=]*=//; s/://g' \
      | /usr/bin/tr '[:lower:]' '[:upper:]' 2>/dev/null || true)
    [[ -n "$candidate_fingerprint" ]] || continue
    if /usr/bin/security find-identity -v -p codesigning \
      | /usr/bin/awk -v identity="$candidate_fingerprint" \
        '$2 == identity { found = 1 } END { exit !found }'; then
      provisioning_profile="$candidate_profile"
      selected_expiration="$candidate_epoch"
    fi
  done
fi

if [[ ! -r "$provisioning_profile" ]]; then
  echo "No valid Aurelia provisioning profile is available for $bundle_identifier." >&2
  echo "Renew it in Xcode or set AURELIA_PROVISIONING_PROFILE to a valid profile." >&2
  exit 1
fi
if ! /usr/bin/security cms -D -i "$provisioning_profile" >"$profile_plist"; then
  echo "Unable to decode the Aurelia provisioning profile." >&2
  exit 1
fi

profile_bundle_identifier=$(/usr/libexec/PlistBuddy \
  -c 'Print :Entitlements:com.apple.application-identifier' "$profile_plist" 2>/dev/null || true)
profile_team_identifier=$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$profile_plist" 2>/dev/null || true)
if [[ "$profile_bundle_identifier" != "$team_identifier.$bundle_identifier" \
  || "$profile_team_identifier" != "$team_identifier" ]]; then
  echo "The Aurelia provisioning profile does not match $bundle_identifier and team $team_identifier." >&2
  exit 1
fi

profile_expiration=$(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$profile_plist" 2>/dev/null || true)
profile_expiration_epoch=$(/bin/date -j -f '%a %b %d %H:%M:%S %Z %Y' \
  "$profile_expiration" +%s 2>/dev/null || true)
if [[ -z "$profile_expiration_epoch" || "$profile_expiration_epoch" -le $(/bin/date +%s) ]]; then
  echo "The Aurelia provisioning profile is expired or has an unreadable expiration date." >&2
  exit 1
fi

profile_certificate_fingerprint=$(/usr/bin/security cms -D -i "$provisioning_profile" \
  | /usr/bin/plutil -extract DeveloperCertificates.0 raw -o - - \
  | /usr/bin/base64 -D \
  | /usr/bin/openssl x509 -inform DER -noout -fingerprint -sha1 \
  | /usr/bin/sed -E 's/^[^=]*=//; s/://g' \
  | /usr/bin/tr '[:lower:]' '[:upper:]')
signing_identity=${AURELIA_SIGNING_IDENTITY:-$profile_certificate_fingerprint}
if [[ -z "$signing_identity" ]]; then
  echo "No valid Apple Development signing identity is available." >&2
  exit 1
fi
if [[ "$signing_identity" != "$profile_certificate_fingerprint" ]]; then
  echo "The selected signing identity is not authorized by the Aurelia provisioning profile." >&2
  echo "Set AURELIA_SIGNING_IDENTITY to its matching SHA-1 fingerprint." >&2
  exit 1
fi
if ! /usr/bin/security find-identity -v -p codesigning \
  | /usr/bin/awk -v identity="$signing_identity" '$2 == identity { found = 1 } END { exit !found }'; then
  echo "The provisioning profile's signing identity is not available in the keychain." >&2
  exit 1
fi
if [[ "$distribution" == developer-id ]]; then
  if ! /usr/bin/security find-identity -v -p codesigning \
    | /usr/bin/awk -v identity="$signing_identity" \
      '$2 == identity && /Developer ID Application:/ { found = 1 } END { exit !found }'; then
    echo "Public distribution requires a Developer ID Application identity, not Apple Development." >&2
    exit 1
  fi
  if [[ "$(/usr/libexec/PlistBuddy -c 'Print :ProvisionsAllDevices' "$profile_plist" 2>/dev/null || true)" != true ]]; then
    echo "Public distribution requires a Developer ID provisioning profile for all devices." >&2
    exit 1
  fi
fi
fi

mkdir -p "$publish_root"
"$repository_root/scripts/prepare-vlckit.sh"
"$repository_root/scripts/verify-build-number.sh"

for runtime in osx-arm64; do
  "$dotnet_bin" restore "$repository_root/src/Aurelia.Server/Aurelia.Server.csproj" \
    --runtime "$runtime"
  "$dotnet_bin" publish "$repository_root/src/Aurelia.Server/Aurelia.Server.csproj" \
    --configuration Release \
    --runtime "$runtime" \
    --self-contained true \
    --no-restore \
    --output "$publish_root/$runtime"
done

DEVELOPER_DIR="$developer_dir" xcodebuild -quiet \
  -project "$repository_root/clients/macos/Aurelia.xcodeproj" \
  -scheme Aurelia \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived_data" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  CODE_SIGNING_ALLOWED=NO \
  build

/usr/bin/ditto "$derived_data/Build/Products/Release/Aurelia.app" "$candidate"
for agent in com.lucas.aurelia.media.host.background com.lucas.aurelia.media.host.login; do
  agent_plist="$candidate/Contents/Library/LaunchAgents/$agent.plist"
  /usr/bin/plutil -lint "$agent_plist"
  agent_program=$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$agent_plist")
  if [[ "$agent_program" != 'Contents/Helpers/Aurelia Server Host.app/Contents/MacOS/AureliaServerHost' \
    || ! -x "$candidate/$agent_program" ]]; then
    echo "The launch agent does not point to the bundled Aurelia host." >&2
    exit 1
  fi
done
if [[ "$distribution" != profileless-development ]]; then
  /usr/bin/ditto "$provisioning_profile" "$candidate/Contents/embedded.provisionprofile"
else
  # Do not silently inherit an embedded profile from a future build step.
  if find "$candidate" -name embedded.provisionprofile -print -quit | grep -q .; then
    echo "A profileless candidate unexpectedly contains a provisioning profile." >&2
    exit 1
  fi
fi
mkdir -p "$candidate/Contents/Resources/Server"
mkdir -p "$candidate/Contents/Resources/ThirdPartyNotices"
cp "$repository_root/LICENSE" "$candidate/Contents/Resources/LICENSE"
for runtime in osx-arm64; do
  /usr/bin/ditto "$publish_root/$runtime" "$candidate/Contents/Resources/Server/$runtime"
  assets_path=$("$dotnet_bin" msbuild "$repository_root/src/Aurelia.Server/Aurelia.Server.csproj" \
    -getProperty:ProjectAssetsFile)
  "$repository_root/scripts/collect-third-party-notices.sh" \
    "$publish_root/$runtime/Aurelia.Server.deps.json" "$assets_path" \
    "$candidate/Contents/Resources/ThirdPartyNotices/$runtime"
done
# Live conversion for web browsers uses the app's own LGPL ffmpeg beside the server runtime;
# the loop below signs it with the hardened runtime like every other server binary.
ffmpeg_root=$("$repository_root/scripts/build-ffmpeg-macos.sh" | tail -n 1)
[[ -x "$ffmpeg_root/ffmpeg" && -x "$ffmpeg_root/ffprobe" ]] || { echo "The Mac ffmpeg build failed." >&2; exit 1; }
/usr/bin/ditto "$ffmpeg_root" "$candidate/Contents/Resources/Server/ffmpeg"
# The Mac app is for Apple silicon only. VLCKit and some NuGet native libraries (SkiaSharp) ship
# universal, so drop their Intel slices before everything is signed again below.
while IFS= read -r -d '' binary; do
  if file "$binary" | grep -q 'Mach-O universal' \
    && [[ " $(/usr/bin/lipo -archs "$binary") " == *" x86_64 "* ]] \
    && [[ " $(/usr/bin/lipo -archs "$binary") " == *" arm64 "* ]]; then
    /usr/bin/lipo "$binary" -remove x86_64 -output "$binary"
  fi
done < <(find "$candidate" -type f -print0)

while IFS= read -r -d '' binary; do
  if file "$binary" | grep -q 'Mach-O'; then
    if [[ "${binary:t}" == 'Aurelia.Server' ]]; then
      codesign --force --sign "$signing_identity" --options runtime "$timestamp_option" \
        --entitlements "$repository_root/clients/macos/Configuration/ServerRuntime.entitlements" \
        "$binary"
    else
      codesign --force --sign "$signing_identity" --options runtime "$timestamp_option" "$binary"
    fi
  fi
done < <(find "$candidate/Contents/Resources/Server" -type f -print0)

codesign --force --sign "$signing_identity" --options runtime "$timestamp_option" \
  "$candidate/Contents/Frameworks/VLCKit.framework"
python3 "$repository_root/scripts/verify-vlc-audio-filters.py" \
  "$candidate/Contents/Frameworks/VLCKit.framework/VLCKit"
codesign --force --sign "$signing_identity" --options runtime "$timestamp_option" \
  --entitlements "$repository_root/clients/macos/Configuration/AureliaServerHost.entitlements" \
  "$candidate/Contents/Helpers/Aurelia Server Host.app"
cp "$repository_root/clients/macos/Configuration/Aurelia.entitlements" "$release_entitlements"
if [[ "$distribution" == profileless-development ]]; then
  # Existing Mac queries target the ordinary file-based Keychain, not the
  # restricted Data Protection access groups. The sandbox, selected-file
  # permissions, network permissions and team-prefixed App Group stay intact.
  /usr/libexec/PlistBuddy -c 'Delete :keychain-access-groups' "$release_entitlements"
  /bin/zsh "$repository_root/scripts/verify-profileless-macos-entitlements.sh" \
    "$release_entitlements" "$repository_root/clients/macos/Configuration/AureliaServerHost.entitlements"
else
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $team_identifier.$bundle_identifier" \
  "$release_entitlements"
/usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $team_identifier" \
  "$release_entitlements"
fi
# "Check for Updates…" reads the releases of the GitHub repository this app is built from.
origin=$(git -C "$repository_root" remote get-url origin 2>/dev/null || true)
update_repository=${origin#https://github.com/}
update_repository=${update_repository#git@github.com:}
update_repository=${update_repository#ssh://git@github.com/}
update_repository=${update_repository%.git}
if [[ "$update_repository" == */* && "$update_repository" != */*/* ]]; then
  plutil -replace AureliaUpdateRepository -string "$update_repository" "$candidate/Contents/Info.plist"
fi
codesign --force --sign "$signing_identity" --options runtime "$timestamp_option" \
  --entitlements "$release_entitlements" \
  "$candidate"
codesign --verify --deep --strict --verbose=2 "$candidate"
while IFS= read -r -d '' binary; do
  if file "$binary" | grep -q 'Mach-O' && /usr/bin/lipo "$binary" -verify_arch x86_64 2>/dev/null; then
    echo "An Intel slice is left in ${binary#$candidate/}; the Mac app is arm64 only." >&2
    exit 1
  fi
done < <(find "$candidate" -type f -print0)
if [[ "$distribution" == profileless-development ]]; then
  if find "$candidate" -name embedded.provisionprofile -print -quit | grep -q .; then
    echo "The signed profileless candidate unexpectedly contains a provisioning profile." >&2
    exit 1
  fi
  /usr/bin/codesign --display --entitlements - --xml "$candidate" \
    >"$stage_root/SignedApplication.entitlements" 2>/dev/null
  /usr/bin/codesign --display --entitlements - --xml \
    "$candidate/Contents/Helpers/Aurelia Server Host.app" \
    >"$stage_root/SignedHelper.entitlements" 2>/dev/null
  /bin/zsh "$repository_root/scripts/verify-profileless-macos-entitlements.sh" \
    "$stage_root/SignedApplication.entitlements" "$stage_root/SignedHelper.entitlements"
fi

if [[ -e "$final_root" ]]; then
  if [[ "$final_root" != "$other_root/Build/Build $build_number" ]]; then
    echo "Refusing to replace an unexpected build directory." >&2
    exit 1
  fi
  rm -rf -- "$final_root"
fi
mkdir -p "$final_root"
/usr/bin/ditto "$candidate" "$final_root/Aurelia.app"
/usr/bin/ditto "$publish_root" "$final_root/Server"

echo "Build $build_number release is available at $final_root"
