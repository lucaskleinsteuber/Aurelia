#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
apple_build=$(sed -n 's/^CURRENT_PROJECT_VERSION = \([0-9][0-9]*\)$/\1/p' "$repository_root/clients/macos/Configuration/BuildNumber.xcconfig")
apple_version=$(sed -n 's/^MARKETING_VERSION = \(.*\)$/\1/p' "$repository_root/clients/macos/Configuration/BuildNumber.xcconfig")
server_build=$(sed -n 's:.*<AureliaBuildNumber>\([0-9][0-9]*\)</AureliaBuildNumber>.*:\1:p' "$repository_root/Directory.Build.props")
server_version=$(sed -n 's:.*<Version>\([^<]*\)</Version>.*:\1:p' "$repository_root/Directory.Build.props")
linux_build=$(sed -n 's:.*<AureliaLinuxBuildNumber>\([0-9][0-9]*\)</AureliaLinuxBuildNumber>.*:\1:p' "$repository_root/clients/linux/Directory.Build.props")
linux_version=$(sed -n 's:.*<Version>\([^<]*\)</Version>.*:\1:p' "$repository_root/clients/linux/Directory.Build.props")
tvos_build=$(sed -n 's/^CURRENT_PROJECT_VERSION = \([0-9][0-9]*\)$/\1/p' "$repository_root/clients/tvos/Configuration/BuildNumber.xcconfig")
tvos_version=$(sed -n 's/^MARKETING_VERSION = \(.*\)$/\1/p' "$repository_root/clients/tvos/Configuration/BuildNumber.xcconfig")
ios_build=$(sed -n 's/^CURRENT_PROJECT_VERSION = \([0-9][0-9]*\)$/\1/p' "$repository_root/clients/ios/Configuration/BuildNumber.xcconfig")
ios_version=$(sed -n 's/^MARKETING_VERSION = \(.*\)$/\1/p' "$repository_root/clients/ios/Configuration/BuildNumber.xcconfig")

valid_version() {
    printf '%s\n' "$1" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
}

check_format() {
    label=$1
    version=$2
    build=$3
    if [ -z "$build" ] || [ "$build" -lt 1 ] || ! valid_version "$version"; then
        echo "Invalid $label version or build." >&2
        exit 1
    fi
}

# Check against known Git tags (when present) that a published product's build never decreases
# and is never reused under a different version (audit REL-REPO-009).
check_tags() {
    label=$1
    prefix=$2
    version=$3
    build=$4
    tags=$(git -C "$repository_root" tag -l 2>/dev/null || true)
    [ -n "$tags" ] || return 0
    highest=$(printf '%s\n' "$tags" | awk -v prefix="$prefix" '
        $0 ~ ("^" prefix "[0-9]+\\.[0-9]+\\.[0-9]+-[0-9]+$") {
            t = $0
            b = t; sub(/^.*-/, "", b)
            if (b + 0 > max) { max = b + 0; best = t }
        }
        END { if (max > 0) printf "%d %s\n", max, best }')
    [ -n "$highest" ] || return 0
    max_build=${highest%% *}
    max_tag=${highest#* }
    if [ "$build" -lt "$max_build" ]; then
        echo "$label build $build is lower than published tag $max_tag." >&2
        exit 1
    fi
    if [ "$build" -eq "$max_build" ] && [ "${prefix}${version}-${build}" != "$max_tag" ]; then
        echo "$label build $build is already used by published tag $max_tag; increase the build number." >&2
        exit 1
    fi
}

check_format "macOS" "$apple_version" "$apple_build"
check_format "server" "$server_version" "$server_build"
check_format "Linux Desktop" "$linux_version" "$linux_build"
check_format "Apple TV" "$tvos_version" "$tvos_build"
check_format "iPhone & iPad" "$ios_version" "$ios_build"

check_tags "Mac" "" "$apple_version" "$apple_build"
check_tags "Server" "server-" "$server_version" "$server_build"
check_tags "Linux Desktop" "linux-app-" "$linux_version" "$linux_build"

printf 'Mac %s (%s)\nServer %s (%s)\nLinux Desktop %s (%s)\nApple TV %s (%s)\niPhone & iPad %s (%s)\n' \
    "$apple_version" "$apple_build" "$server_version" "$server_build" \
    "$linux_version" "$linux_build" "$tvos_version" "$tvos_build" "$ios_version" "$ios_build"
