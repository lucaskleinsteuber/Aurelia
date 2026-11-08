#!/bin/bash
# Installs Aurelia Server with one line, or updates it:
#
#   curl -fsSL https://raw.githubusercontent.com/lucaskleinsteuber/Aurelia/main/packaging/linux/get-aurelia.sh | sudo bash
#
# It finds the newest stable server release for this computer on GitHub, checks the download
# against the release's SHA256SUMS, runs the package's installer and, on a new installation,
# starts the setup questions. Nothing else on the computer is changed.
set -euo pipefail

repository=${AURELIA_REPOSITORY:-lucaskleinsteuber/Aurelia}
# Tests point this at a local stand-in for GitHub's release list.
releases=${AURELIA_RELEASES_URL:-https://api.github.com/repos/$repository/releases?per_page=30}

fail() { echo "$*" >&2; exit 1; }
# apt runs without questions here; Aurelia asks its own afterwards.
export DEBIAN_FRONTEND=noninteractive

[ "$(id -u)" -eq 0 ] || fail "Run it with sudo: curl -fsSL https://raw.githubusercontent.com/$repository/main/packaging/linux/get-aurelia.sh | sudo bash"
command -v systemctl >/dev/null 2>&1 || fail "Aurelia Server needs a Linux system with systemd."
case "$(uname -m)" in
  x86_64|amd64) arch=x64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) fail "Aurelia Server runs on 64-bit Intel, AMD and ARM computers, not on $(uname -m)." ;;
esac

missing=()
for tool in curl jq tar sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [ "${#missing[@]}" -gt 0 ]; then
  command -v apt-get >/dev/null 2>&1 || fail "Install ${missing[*]} with your package manager first."
  echo "Installing ${missing[*]}..."
  apt-get install -y "${missing[@]/sha256sum/coreutils}" >/dev/null 2>&1 \
    || { apt-get update -qq >/dev/null && apt-get install -y "${missing[@]/sha256sum/coreutils}" >/dev/null; } \
    || fail "Could not install ${missing[*]}."
fi

work=$(mktemp -d /var/tmp/aurelia-get.XXXXXX)
trap 'rm -rf "$work"' EXIT

echo "Looking for the newest Aurelia Server..."
curl -fsSL --retry 3 -H 'Accept: application/vnd.github+json' "$releases" -o "$work/releases.json" \
  || fail "GitHub could not be reached. Check the internet connection and try again."
# The stable release with the highest build that has a package for this computer and a checksum list.
newest=$(jq -r --arg arch "$arch" '
  [ .[] | select((.draft | not) and (.prerelease | not))
    | first(.assets[] | select(.name == "SHA256SUMS") | .browser_download_url) as $sums
    | .assets[]
    | (.name | capture("^Aurelia-Server-(?<version>[0-9][0-9.]*)-(?<build>[0-9]+)-linux-" + $arch + "\\.tar\\.gz$")) as $found
    | [($found.build | tonumber), $found.version, .name, .browser_download_url, $sums] ]
  | max_by(.[0]) // empty | .[0] |= tostring | join("\t")' "$work/releases.json")
[ -n "$newest" ] || fail "No Aurelia Server release for $arch was found on GitHub."
IFS=$'\t' read -r build version name url sums_url <<<"$newest"

echo "Downloading Aurelia Server $version ($build)..."
curl -fsSL --retry 3 "$url" -o "$work/$name" || fail "The download failed. Try again."
curl -fsSL --retry 3 "$sums_url" -o "$work/SHA256SUMS" || fail "The checksum list could not be downloaded."
expected=$(awk -v file="$name" '{ sub(/^\*/, "", $2); sub(/^\.\//, "", $2) } $2 == file { print $1 }' "$work/SHA256SUMS")
[ "${#expected}" -eq 64 ] || fail "The release lists no checksum for $name."
[ "$(sha256sum "$work/$name" | cut -d ' ' -f1)" = "$expected" ] \
  || fail "The download does not match its published checksum, so it was not installed."

# Like `aurelia update`: only the package's own folder is unpacked, owned by root, and it must be
# the version and architecture that was chosen.
folder="Aurelia-Server-$version-linux-$arch"
tar -tzf "$work/$name" > "$work/contents"
awk -v folder="$folder" 'index($0, folder "/") != 1 || /(^|\/)\.\.(\/|$)/ { bad = 1 } END { exit bad }' "$work/contents" \
  || fail "The download is not an Aurelia Server package, so it was not installed."
mkdir "$work/package"
tar -xzf "$work/$name" --no-same-owner -C "$work/package"
package="$work/package/$folder"
[ "$(cat "$package/VERSION" 2>/dev/null)" = "$version ($build)" ] && [ "$(cat "$package/ARCHITECTURE" 2>/dev/null)" = "$arch" ] \
  && [ -f "$package/install.sh" ] || fail "The download is not Aurelia Server $version ($build) for $arch, so it was not installed."
was_set_up=false
[ -e /var/lib/aurelia/aurelia.db ] && was_set_up=true
(cd "$package" && ./install.sh)

if $was_set_up; then
  exit 0
fi
# Piped into bash, the questions read from the terminal rather than from this script.
if [ -r /dev/tty ] && [ -w /dev/tty ] && (exec </dev/tty) 2>/dev/null; then
  echo
  echo "Now a few questions to set up Aurelia."
  aurelia setup </dev/tty
fi
