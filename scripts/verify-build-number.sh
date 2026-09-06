#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
dotnet_build=$(sed -n 's:.*<AureliaHomeBuildNumber>\([0-9][0-9]*\)</AureliaHomeBuildNumber>.*:\1:p' "$repository_root/Directory.Build.props")
apple_build=$(sed -n 's/^CURRENT_PROJECT_VERSION = \([0-9][0-9]*\)$/\1/p' "$repository_root/clients/macos/Configuration/BuildNumber.xcconfig")

if [ -z "$dotnet_build" ] || [ -z "$apple_build" ] || [ "$dotnet_build" != "$apple_build" ]; then
    echo "Build number mismatch: server=$dotnet_build macOS=$apple_build" >&2
    exit 1
fi

echo "Build number $dotnet_build is synchronized."
