#!/bin/bash
# Downloads a stable Aurelia Server release for this image, checks it against the release's
# SHA256SUMS and its minisign signature and unpacks it into /opt/aurelia.
set -euo pipefail
# The owner's minisign key, as in `aurelia update`. Every release must be signed with it, old
# builds included: there is no unsigned way in.
signing_public_key=RWT0nYptHNjXQSXnVurY9XXdPF2Ssq5sUlSP+WoBwjA5GPXWnugBc7lE

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

repository=$1
case "$2" in
  amd64|x86_64) arch=x64 ;;
  arm64|aarch64) arch=arm64 ;;
  *) echo "Aurelia Server runs on amd64 and arm64, not on $2." >&2; exit 1 ;;
esac
wanted=${3:-}
work=$(mktemp -d)
newest_in() {
  jq -r --arg arch "$arch" --arg wanted "$wanted" '
  [ .[] | select((.draft | not) and (.prerelease | not))
    | first(.assets[] | select(.name == "SHA256SUMS") | .browser_download_url) as $sums
    | (first(.assets[] | select(.name == "SHA256SUMS.minisig") | .browser_download_url) // "") as $signature
    | .assets[]
    | (.name | capture("^Aurelia-Server-(?<version>[0-9][0-9.]*)-(?<build>[0-9]+)-linux-" + $arch + "\\.tar\\.gz$")) as $found
    | select($wanted == "" or $found.build == $wanted)
    | [($found.build | tonumber), $found.version, .name, .browser_download_url, $sums, $signature] ]
  | max_by(.[0]) // empty | .[0] |= tostring | join("\t")' "$1"
}
# Releases come newest first, 100 to a page, with betas of every product between the stable
# servers: further pages are read until one holds the wanted server (at most five).
newest=""
for page in 1 2 3 4 5; do
  curl -fsSL --retry 3 -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/$repository/releases?per_page=100&page=$page" -o "$work/releases.json"
  newest=$(newest_in "$work/releases.json")
  [ -z "$newest" ] && [ "$(jq length "$work/releases.json")" -ge 100 ] || break
done
[ -n "$newest" ] || { echo "No stable Aurelia Server release for $arch${wanted:+ with build $wanted} was found." >&2; exit 1; }
IFS=$'\t' read -r build version name url sums_url signature_url <<<"$newest"
echo "Aurelia Server $version ($build) for $arch"
curl -fsSL --retry 3 "$url" -o "$work/$name"
curl -fsSL --retry 3 "$sums_url" -o "$work/SHA256SUMS"
[ -n "$signature_url" ] && curl -fsSL --retry 3 "$signature_url" -o "$work/SHA256SUMS.minisig" \
  && mkdir "$work/signature" && signature_valid "$work/SHA256SUMS" "$work/SHA256SUMS.minisig" "$work/signature" \
  || { echo "The release is not signed by the owner of Aurelia." >&2; exit 1; }
expected=$(awk -v file="$name" '{ sub(/^\*/, "", $2); sub(/^\.\//, "", $2) } $2 == file { print $1 }' "$work/SHA256SUMS")
[ "${#expected}" -eq 64 ] && [ "$(sha256sum "$work/$name" | cut -d ' ' -f1)" = "$expected" ] \
  || { echo "The download does not match its published checksum." >&2; exit 1; }
# Like `aurelia update`: only the package's own folder is unpacked, owned by root, and it must be
# the version and architecture that was chosen.
folder="Aurelia-Server-$version-linux-$arch"
tar -tzf "$work/$name" > "$work/contents"
awk -v folder="$folder" 'index($0, folder "/") != 1 || /(^|\/)\.\.(\/|$)/ { bad = 1 } END { exit bad }' "$work/contents" \
  || { echo "The download is not an Aurelia Server package." >&2; exit 1; }
mkdir "$work/package"
tar -xzf "$work/$name" --no-same-owner -C "$work/package"
package="$work/package/$folder"
[ "$(cat "$package/VERSION" 2>/dev/null)" = "$version ($build)" ] && [ "$(cat "$package/ARCHITECTURE" 2>/dev/null)" = "$arch" ] \
  || { echo "The download is not Aurelia Server $version ($build) for $arch." >&2; exit 1; }
install -d /opt/aurelia
cp -R "$package/server" "$package/notices" /opt/aurelia/
install -m 0644 "$package/VERSION" /opt/aurelia/VERSION
chmod -R u=rwX,go=rX /opt/aurelia
chmod 0755 /opt/aurelia/server/Aurelia.Server
rm -rf "$work"
