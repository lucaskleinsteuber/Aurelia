#!/bin/sh
set -eu

version=3.7.3
archive_name=MobileVLCKit-3.7.3-319ed2c0-79128878.tar.xz
expected_sha256=0d04059906962ddc9a7bd1ebaa12e1f9ae85eb2466116a97a2f46886dd27a0a9
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repository_root/scripts/workspace-paths.sh"
cache_root="$other_root/Package Cache/MobileVLCKit/$version"
archive_path="$cache_root/MobileVLCKit-$version.tar.xz"
package_root="$cache_root/MobileVLCKit-binary"
dependency_root=${MOBILEVLCKIT_ROOT:-"$repository_root/clients/ios/Dependencies"}
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
    echo "MobileVLCKit archive checksum mismatch; the dependency was not prepared." >&2
    exit 1
fi
if [ ! -d "$package_root/MobileVLCKit.xcframework" ]; then
    tar -xf "$archive_path" -C "$cache_root"
fi
simulator_binary="$package_root/MobileVLCKit.xcframework/ios-arm64_i386_x86_64-simulator/MobileVLCKit.framework/MobileVLCKit"
if [ ! -f "$simulator_binary" ] || [ ! -f "$package_root/COPYING.txt" ]; then
    echo "The pinned MobileVLCKit simulator framework or license is missing." >&2
    exit 1
fi

ln -sfn "$package_root/MobileVLCKit.xcframework" "$dependency_root/MobileVLCKit.xcframework"
ln -sfn "$package_root/COPYING.txt" "$dependency_root/MobileVLCKit-COPYING.txt"
echo "Prepared MobileVLCKit $version from the verified official production archive."
