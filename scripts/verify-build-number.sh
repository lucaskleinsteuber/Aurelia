#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
apple_build=$(sed -n 's/^CURRENT_PROJECT_VERSION = \([0-9][0-9]*\)$/\1/p' "$repository_root/clients/macos/Configuration/BuildNumber.xcconfig")
apple_version=$(sed -n 's/^MARKETING_VERSION = \(.*\)$/\1/p' "$repository_root/clients/macos/Configuration/BuildNumber.xcconfig")
server_build=$(sed -n 's:.*<AureliaBuildNumber>\([0-9][0-9]*\)</AureliaBuildNumber>.*:\1:p' "$repository_root/Directory.Build.props")
server_version=$(sed -n 's:.*<Version>\([^<]*\)</Version>.*:\1:p' "$repository_root/Directory.Build.props")

valid_version() {
    printf '%s\n' "$1" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
}

[ -n "$apple_build" ] && valid_version "$apple_version" || { echo "Invalid macOS version or build." >&2; exit 1; }
[ -n "$server_build" ] && valid_version "$server_version" || { echo "Invalid server version or build." >&2; exit 1; }
printf 'Mac %s (%s)\nServer %s (%s)\n' "$apple_version" "$apple_build" "$server_version" "$server_build"
