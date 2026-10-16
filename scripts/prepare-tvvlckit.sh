#!/bin/sh
set -eu

version=3.7.3
archive_name=TVVLCKit-3.7.3-319ed2c0-79128878.tar.xz
expected_sha256=b5f90c226ed54d9dc1c03901c60dc7749b74a53caace2c3047e4c0b7a063e46c
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repository_root/scripts/workspace-paths.sh"
cache_root="$other_root/Package Cache/TVVLCKit/$version"
archive_path="$cache_root/TVVLCKit-$version.tar.xz"
package_root="$cache_root/TVVLCKit-binary"
dependency_root=${TVVLCKIT_ROOT:-"$repository_root/clients/tvos/Dependencies"}
download_url="https://download.videolan.org/cocoapods/prod/$archive_name"

mkdir -p "$cache_root" "$dependency_root"
if [ ! -f "$archive_path" ]; then
    partial_path="$archive_path.partial.$$"
    trap 'rm -f "$partial_path"' EXIT HUP INT TERM
    curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --output "$partial_path" "$download_url"
    mv "$partial_path" "$archive_path"
    trap - EXIT HUP INT TERM
fi
actual_sha256=$(shasum -a 256 "$archive_path" | awk '{print $1}')
if [ "$actual_sha256" != "$expected_sha256" ]; then
    echo "TVVLCKit archive checksum mismatch; the dependency was not prepared." >&2
    exit 1
fi
if [ ! -d "$package_root/TVVLCKit.xcframework" ]; then
    tar -xf "$archive_path" -C "$cache_root"
fi
framework_binary="$package_root/TVVLCKit.xcframework/tvos-arm64/TVVLCKit.framework/TVVLCKit"
if [ ! -f "$framework_binary" ] || [ ! -f "$package_root/COPYING.txt" ]; then
    echo "The pinned TVVLCKit device framework or license is missing." >&2
    exit 1
fi
if [ "$(xcrun lipo -archs "$framework_binary")" != arm64 ]; then
    echo "The TVVLCKit device framework does not contain the expected arm64 architecture." >&2
    exit 1
fi
# Xcode signs only its embedded copy. Keep the verified vendor package intact.
ln -sfn "$package_root/TVVLCKit.xcframework" "$dependency_root/TVVLCKit.xcframework"
ln -sfn "$package_root/COPYING.txt" "$dependency_root/TVVLCKit-COPYING.txt"
echo "Prepared TVVLCKit $version from the verified official production archive."
