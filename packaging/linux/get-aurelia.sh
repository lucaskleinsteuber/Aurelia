#!/bin/bash
# Installs Aurelia Server with one line, or updates it:
#
#   curl -fsSL https://raw.githubusercontent.com/lucaskleinsteuber/Aurelia/main/packaging/linux/get-aurelia.sh | sudo bash
#
# It finds the newest stable server release for this computer on GitHub, checks the download
# against the release's SHA256SUMS and its minisign signature, runs the package's installer and,
# on a new installation, starts the setup questions. Nothing else on the computer is changed.
set -euo pipefail

repository=${AURELIA_REPOSITORY:-lucaskleinsteuber/Aurelia}
# Tests point this at a local stand-in for GitHub's release list.
releases=${AURELIA_RELEASES_URL:-https://api.github.com/repos/$repository/releases?per_page=30}
# The owner's minisign key and the first signed build, as in `aurelia update`; tests with a
# stand-in for GitHub sign with their own key.
signing_public_key=RWT0nYptHNjXQSXnVurY9XXdPF2Ssq5sUlSP+WoBwjA5GPXWnugBc7lE
first_signed_build=153
[ -n "${AURELIA_RELEASES_URL:-}" ] && signing_public_key=${AURELIA_SIGNING_PUBLIC_KEY:-$signing_public_key}

fail() { echo "$*" >&2; exit 1; }

# Succeeds when $2 is a minisign signature of $1 made with signing_public_key, checked with
# openssl so that no further program is needed. Only the prehashed form that minisign writes is
# accepted. $3 is an empty folder for the intermediate files.
signature_valid() {
  local file=$1 signature=$2 scratch=$3
  base64 -d <<<"$signing_public_key" > "$scratch/key.bin" 2>/dev/null || return 1
  sed -n 2p "$signature" | base64 -d > "$scratch/signature.bin" 2>/dev/null || return 1
  [ "$(wc -c < "$scratch/key.bin")" -eq 42 ] && [ "$(wc -c < "$scratch/signature.bin")" -eq 74 ] || return 1
  [ "$(head -c 2 "$scratch/key.bin")" = Ed ] && [ "$(head -c 2 "$scratch/signature.bin")" = ED ] || return 1
  [ "$(head -c 10 "$scratch/key.bin" | tail -c 8 | od -An -tx1)" \
    = "$(head -c 10 "$scratch/signature.bin" | tail -c 8 | od -An -tx1)" ] || return 1
  { printf '\060\052\060\005\006\003\053\145\160\003\041\000'; tail -c 32 "$scratch/key.bin"; } > "$scratch/key.der"
  tail -c 64 "$scratch/signature.bin" > "$scratch/signature.raw"
  openssl dgst -blake2b512 -binary "$file" > "$scratch/hash" 2>/dev/null || return 1
  openssl pkeyutl -verify -pubin -keyform DER -inkey "$scratch/key.der" -rawin -in "$scratch/hash" \
    -sigfile "$scratch/signature.raw" >/dev/null 2>&1
}
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
for tool in curl jq tar sha256sum openssl; do
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
# The stable release with the highest build that has a package for this computer and a checksum
# list, with the address of the list's signature last (empty without one).
newest=$(jq -r --arg arch "$arch" '
  [ .[] | select((.draft | not) and (.prerelease | not))
    | first(.assets[] | select(.name == "SHA256SUMS") | .browser_download_url) as $sums
    | (first(.assets[] | select(.name == "SHA256SUMS.minisig") | .browser_download_url) // "") as $signature
    | .assets[]
    | (.name | capture("^Aurelia-Server-(?<version>[0-9][0-9.]*)-(?<build>[0-9]+)-linux-" + $arch + "\\.tar\\.gz$")) as $found
    | [($found.build | tonumber), $found.version, .name, .browser_download_url, $sums, $signature] ]
  | max_by(.[0]) // empty | .[0] |= tostring | join("\t")' "$work/releases.json")
[ -n "$newest" ] || fail "No Aurelia Server release for $arch was found on GitHub."
IFS=$'\t' read -r build version name url sums_url signature_url <<<"$newest"

echo "Downloading Aurelia Server $version ($build)..."
curl -fsSL --retry 3 "$url" -o "$work/$name" || fail "The download failed. Try again."
curl -fsSL --retry 3 "$sums_url" -o "$work/SHA256SUMS" || fail "The checksum list could not be downloaded."
if [ "$build" -ge "$first_signed_build" ]; then
  unsigned="The release is not signed by the owner of Aurelia, so it was not installed."
  [ -n "$signature_url" ] || fail "$unsigned"
  curl -fsSL --retry 3 "$signature_url" -o "$work/SHA256SUMS.minisig" || fail "The signature could not be downloaded."
  mkdir "$work/signature"
  signature_valid "$work/SHA256SUMS" "$work/SHA256SUMS.minisig" "$work/signature" || fail "$unsigned"
fi
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
