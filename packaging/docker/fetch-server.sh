#!/bin/bash
# Downloads a stable Aurelia Server release for this image, checks it against the release's
# SHA256SUMS and unpacks it into /opt/aurelia.
set -euo pipefail
repository=$1
case "$2" in
  amd64|x86_64) arch=x64 ;;
  arm64|aarch64) arch=arm64 ;;
  *) echo "Aurelia Server runs on amd64 and arm64, not on $2." >&2; exit 1 ;;
esac
wanted=${3:-}
work=$(mktemp -d)
curl -fsSL --retry 3 -H 'Accept: application/vnd.github+json' \
  "https://api.github.com/repos/$repository/releases?per_page=30" -o "$work/releases.json"
newest=$(jq -r --arg arch "$arch" --arg wanted "$wanted" '
  [ .[] | select((.draft | not) and (.prerelease | not))
    | first(.assets[] | select(.name == "SHA256SUMS") | .browser_download_url) as $sums
    | .assets[]
    | (.name | capture("^Aurelia-Server-(?<version>[0-9][0-9.]*)-(?<build>[0-9]+)-linux-" + $arch + "\\.tar\\.gz$")) as $found
    | select($wanted == "" or $found.build == $wanted)
    | [($found.build | tonumber), $found.version, .name, .browser_download_url, $sums] ]
  | max_by(.[0]) // empty | .[0] |= tostring | join("\t")' "$work/releases.json")
[ -n "$newest" ] || { echo "No stable Aurelia Server release for $arch${wanted:+ with build $wanted} was found." >&2; exit 1; }
IFS=$'\t' read -r build version name url sums_url <<<"$newest"
echo "Aurelia Server $version ($build) for $arch"
curl -fsSL --retry 3 "$url" -o "$work/$name"
curl -fsSL --retry 3 "$sums_url" -o "$work/SHA256SUMS"
expected=$(awk -v file="$name" '{ sub(/^\*/, "", $2); sub(/^\.\//, "", $2) } $2 == file { print $1 }' "$work/SHA256SUMS")
[ "${#expected}" -eq 64 ] && [ "$(sha256sum "$work/$name" | cut -d ' ' -f1)" = "$expected" ] \
  || { echo "The download does not match its published checksum." >&2; exit 1; }
tar -xzf "$work/$name" -C "$work"
package=$(find "$work" -mindepth 2 -maxdepth 2 -name install.sh -printf '%h\n' | head -n 1)
install -d /opt/aurelia
cp -R "$package/server" "$package/notices" /opt/aurelia/
install -m 0644 "$package/VERSION" /opt/aurelia/VERSION
chmod -R u=rwX,go=rX /opt/aurelia
chmod 0755 /opt/aurelia/server/Aurelia.Server
rm -rf "$work"
