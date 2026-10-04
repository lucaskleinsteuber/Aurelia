#!/bin/sh
set -eu

version=3.7.3
archive_name=VLCKit-3.7.3-319ed2c0-79128878.tar.xz
expected_sha256=019afdae4e2e2d0f3ac325fac8f7ba0af25dca70b9d157df7d60db88e0be8e5d

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repository_root/scripts/workspace-paths.sh"
cache_root="$other_root/Package Cache/VLCKit/$version"
archive_path="$cache_root/VLCKit-$version.tar.xz"
package_root="$cache_root/VLCKit - binary package"
dependency_root="$repository_root/clients/macos/Dependencies"
download_url="https://download.videolan.org/cocoapods/prod/$archive_name"

mkdir -p "$cache_root" "$dependency_root"

if [ ! -f "$archive_path" ]; then
    partial_path="$archive_path.partial"
    curl --fail --location --retry 3 --output "$partial_path" "$download_url"
    mv "$partial_path" "$archive_path"
fi

actual_sha256=$(shasum -a 256 "$archive_path" | awk '{print $1}')
if [ "$actual_sha256" != "$expected_sha256" ]; then
    echo "VLCKit archive checksum mismatch." >&2
    echo "Expected: $expected_sha256" >&2
    echo "Actual:   $actual_sha256" >&2
    exit 1
fi

if [ ! -d "$package_root/VLCKit.xcframework" ]; then
    tar -xf "$archive_path" -C "$cache_root"
fi

if [ ! -f "$package_root/COPYING.txt" ]; then
    echo "VLCKit license file is missing from the official package." >&2
    exit 1
fi

# The official archive is pre-signed. Xcode must strip and then re-sign the
# embedded copy for Aurelia, so remove only the cached binary signature.
framework_binary="$package_root/VLCKit.xcframework/macos-arm64_x86_64/VLCKit.framework/Versions/A/VLCKit"
if [ ! -f "$framework_binary" ]; then
    echo "VLCKit macOS framework binary is missing from the official package." >&2
    exit 1
fi
if codesign --display "$framework_binary" >/dev/null 2>&1; then
    codesign --remove-signature "$framework_binary"
fi

ln -sfn "$package_root/VLCKit.xcframework" "$dependency_root/VLCKit.xcframework"
ln -sfn "$package_root/COPYING.txt" "$dependency_root/VLCKit-COPYING.txt"

echo "Prepared VLCKit $version from the verified official archive."
