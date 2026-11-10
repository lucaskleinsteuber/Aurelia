#!/bin/bash
# Checks the signature check that `aurelia update`, the one-line installer and the Docker build
# share: all three carry the same check, the owner's key (the Linux app's) and the same first
# signed build, and the check accepts only a valid signature by that key. Synthetic files and a
# throwaway key only; with minisign installed it also confirms both formats match minisign's.
# Needs openssl 1.1.1 or newer (on macOS from Homebrew).
set -euo pipefail
repository=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repository/scripts/synthetic-signing.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

scripts=(packaging/linux/aurelia packaging/linux/get-aurelia.sh packaging/docker/fetch-server.sh)
function_of() { sed -n '/^# Succeeds when \$2 is a minisign signature/,/^}$/p' "$repository/$1"; }
value_of() { sed -n "s/^$2=\\([A-Za-z0-9+\\/=]*\\)\$/\\1/p" "$repository/$1"; }

function_of "${scripts[0]}" > "$work/check.sh"
[ "$(grep -c '' "$work/check.sh")" -gt 5 ] || fail "${scripts[0]} has no signature check"
app_key=$(sed -n 's/.*SigningPublicKey = "\([A-Za-z0-9+\/=]*\)";.*/\1/p' \
  "$repository/clients/linux/Aurelia.Linux.Core/Updates/UpdateFeed.cs")
build=$(sed -n 's/.*<AureliaBuildNumber>\([0-9]*\)<.*/\1/p' "$repository/Directory.Build.props")
for script in "${scripts[@]}"; do
  function_of "$script" | cmp -s - "$work/check.sh" || fail "$script checks signatures differently"
  [ "$(value_of "$script" signing_public_key)" = "$app_key" ] || fail "$script does not carry the owner's key"
  first=$(value_of "$script" first_signed_build)
  [ "$first" = "$(value_of "${scripts[0]}" first_signed_build)" ] || fail "$script starts signatures at another build"
  # Every build from the next one on must be signed.
  [ -n "$first" ] && [ "$first" -le $((build + 1)) ] || fail "$script lets build $((build + 1)) go unsigned"
done
grep -F 'packaging/linux/aurelia' "$repository/scripts/publish-release.sh" >/dev/null \
  && grep -F 'SHA256SUMS.minisig' "$repository/scripts/publish-release.sh" >/dev/null \
  || fail "server releases are not signed when they are published"

# `aurelia update` finds the signature next to the package, and knows when there is none.
sed -n '/^newest_package() {$/,/^}$/p' "$repository/packaging/linux/aurelia" > "$work/newest.sh"
. "$work/newest.sh"
arch=x64
jq -n '[{draft: false, prerelease: false, assets: [
  {name: "Aurelia-Server-9.9.9-999-linux-x64.tar.gz", url: "https://example.invalid/package"},
  {name: "SHA256SUMS", url: "https://example.invalid/sums"},
  {name: "SHA256SUMS.minisig", url: "https://example.invalid/signature"}]}]' > "$work/signed.json"
IFS=$'\t' read -r _ _ _ _ sums_url signature_url <<<"$(newest_package "$work/signed.json")"
[ "$sums_url" = https://example.invalid/sums ] && [ "$signature_url" = https://example.invalid/signature ] \
  || fail "aurelia update does not find a release's signature"
jq 'map(.assets |= map(select(.name != "SHA256SUMS.minisig")))' "$work/signed.json" > "$work/unsigned.json"
IFS=$'\t' read -r _ _ _ _ sums_url signature_url <<<"$(newest_package "$work/unsigned.json")"
[ "$sums_url" = https://example.invalid/sums ] && [ -z "$signature_url" ] \
  || fail "aurelia update does not notice a release without a signature"

. "$work/check.sh"
check() { rm -rf "$work/scratch" && mkdir "$work/scratch" && signature_valid "$1" "$2" "$work/scratch"; }

mkdir "$work/key" "$work/other"
signing_public_key=$(synthetic_signing_key "$work/key")
other_key=$(synthetic_signing_key "$work/other")
printf '%064d  ./Aurelia-Server-9.9.9-999-linux-x64.tar.gz\n' 0 > "$work/SHA256SUMS"
synthetic_sign "$work/key" "$work/SHA256SUMS" "Aurelia Server 9.9.9 (999)"
check "$work/SHA256SUMS" "$work/SHA256SUMS.minisig" || fail "a valid signature was refused"

# A changed list.
cp "$work/SHA256SUMS" "$work/changed"
cp "$work/SHA256SUMS.minisig" "$work/changed.minisig"
printf '%064d  ./other.tar.gz\n' 1 >> "$work/changed"
if check "$work/changed" "$work/changed.minisig"; then fail "a changed checksum list was accepted"; fi

# Another key, also one that claims the right key's number.
cp "$work/SHA256SUMS" "$work/foreign"
synthetic_sign "$work/other" "$work/foreign" "Aurelia Server 9.9.9 (999)"
if check "$work/foreign" "$work/foreign.minisig"; then fail "a signature by another key was accepted"; fi
cp "$work/key/synthetic-key.id" "$work/other/synthetic-key.id"
synthetic_sign "$work/other" "$work/foreign" "Aurelia Server 9.9.9 (999)"
if check "$work/foreign" "$work/foreign.minisig"; then fail "another key with the owner's key number was accepted"; fi

# Not prehashed, cut short, or no signature at all.
sed '2s/^RU/RW/' "$work/SHA256SUMS.minisig" > "$work/legacy.minisig"
[ "$(sed -n 2p "$work/legacy.minisig" | base64 -d | head -c 2)" = Ed ] || fail "the legacy form was not made"
if check "$work/SHA256SUMS" "$work/legacy.minisig"; then fail "the legacy signature form was accepted"; fi
sed '2s/.\{8\}$//' "$work/SHA256SUMS.minisig" > "$work/short.minisig"
if check "$work/SHA256SUMS" "$work/short.minisig"; then fail "a shortened signature was accepted"; fi
printf 'not a signature\n' > "$work/garbage.minisig"
if check "$work/SHA256SUMS" "$work/garbage.minisig"; then fail "a broken signature file was accepted"; fi
: > "$work/empty.minisig"
if check "$work/SHA256SUMS" "$work/empty.minisig"; then fail "an empty signature file was accepted"; fi

if command -v minisign >/dev/null 2>&1; then
  minisign -V -P "$signing_public_key" -m "$work/SHA256SUMS" >/dev/null \
    || fail "minisign does not accept the synthetic signature"
  minisign -G -W -p "$work/real.pub" -s "$work/real.key" >/dev/null
  minisign -S -s "$work/real.key" -m "$work/SHA256SUMS" -x "$work/real.minisig" -t "Aurelia Server 9.9.9 (999)" >/dev/null
  signing_public_key=$(sed -n 2p "$work/real.pub")
  check "$work/SHA256SUMS" "$work/real.minisig" || fail "a signature made by minisign was refused"
else
  echo "minisign is not installed; the comparison with minisign itself was skipped."
fi
echo "Server update signatures: all checks passed."
