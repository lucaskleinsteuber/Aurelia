#!/bin/bash
# Checks the one-line installer packaging/linux/get-aurelia.sh against a local stand-in for GitHub
# Releases (file:// addresses) with synthetic packages, without root: id, systemctl and the
# aurelia command are stand-ins, and each package's install.sh only leaves a marker. Nothing on
# the computer is installed or changed. Releases are signed with a throwaway key. Needs curl, jq,
# tar, sha256sum and openssl 1.1.1 or newer (on macOS from Homebrew).
set -euo pipefail
repository=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repository/scripts/synthetic-signing.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/key" "$work/other"
signing_key=$(synthetic_signing_key "$work/key")
synthetic_signing_key "$work/other" >/dev/null
case "$(uname -m)" in
  x86_64|amd64) arch=x64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) echo "This check runs on x64 and arm64 only." >&2; exit 1 ;;
esac
mkdir -p "$work/bin"
printf '#!/bin/bash\n[ "${1:-}" = -u ] && { echo 0; exit 0; }\nexec /usr/bin/id "$@"\n' > "$work/bin/id"
printf '#!/bin/bash\nexit 0\n' > "$work/bin/systemctl"
printf '#!/bin/bash\nexit 0\n' > "$work/bin/aurelia"
chmod +x "$work/bin/"*
fail() { echo "FAIL: $*" >&2; exit 1; }

# A release with one package. $1 names the case; $2 adds an entry outside the package folder;
# $3 signs its checksum list with the test key (key), another key (other) or not at all (none);
# $4 is its build.
release() {
  local name=$1 extra=${2:-} signer=${3:-key} version=9.9.9 build=${4:-999}
  local folder="Aurelia-Server-$version-linux-$arch" dir="$work/$name"
  mkdir -p "$dir/stage/$folder"
  printf '%s (%s)\n' "$version" "$build" > "$dir/stage/$folder/VERSION"
  printf '%s\n' "$arch" > "$dir/stage/$folder/ARCHITECTURE"
  printf '#!/bin/bash\ntouch "%s/installed"\n' "$dir" > "$dir/stage/$folder/install.sh"
  chmod +x "$dir/stage/$folder/install.sh"
  local entries=("$folder")
  if [ -n "$extra" ]; then
    mkdir -p "$dir/stage/$extra"
    printf '#!/bin/bash\ntouch "%s/installed"\n' "$dir" > "$dir/stage/$extra/install.sh"
    chmod +x "$dir/stage/$extra/install.sh"
    entries=("$extra" "$folder")
  fi
  local archive="Aurelia-Server-$version-$build-linux-$arch.tar.gz"
  tar -czf "$dir/$archive" -C "$dir/stage" "${entries[@]}"
  (cd "$dir" && sha256sum "$archive" > SHA256SUMS)
  local signature=""
  if [ "$signer" != none ]; then
    synthetic_sign "$work/$signer" "$dir/SHA256SUMS" "Aurelia Server $version ($build)"
    signature="file://$dir/SHA256SUMS.minisig"
  fi
  jq -n --arg archive "$archive" --arg url "file://$dir/$archive" --arg sums "file://$dir/SHA256SUMS" \
    --arg signature "$signature" \
    '[{draft: false, prerelease: false, assets: ([{name: $archive, browser_download_url: $url}, {name: "SHA256SUMS", browser_download_url: $sums}]
      + if $signature == "" then [] else [{name: "SHA256SUMS.minisig", browser_download_url: $signature}] end)}]' \
    > "$dir/releases.json"
}
install_from() {
  PATH="$work/bin:$PATH" AURELIA_RELEASES_URL="file://$work/$1/releases.json" AURELIA_SIGNING_PUBLIC_KEY="$signing_key" \
    bash "$repository/packaging/linux/get-aurelia.sh" </dev/null >"$work/$1/output" 2>&1
}

release good
install_from good || { cat "$work/good/output" >&2; fail "a valid package was not installed"; }
[ -e "$work/good/installed" ] || fail "the package's installer did not run"

# A package with a second folder must be refused before anything in it runs.
release foreign "Other-Folder"
if install_from foreign; then fail "a package with a foreign folder was installed"; fi
[ ! -e "$work/foreign/installed" ] || fail "an installer outside the package folder ran"
grep -F 'is not an Aurelia Server package' "$work/foreign/output" >/dev/null || fail "the refusal does not say why"

# A release that a stranger changed: no signature, or one by another key.
for signer in none other; do
  release "unsigned-$signer" "" "$signer"
  if install_from "unsigned-$signer"; then fail "a release signed by $signer was installed"; fi
  [ ! -e "$work/unsigned-$signer/installed" ] || fail "the installer of a release signed by $signer ran"
  grep -F 'not signed by the owner' "$work/unsigned-$signer/output" >/dev/null || fail "the refusal does not say why"
done

# Releases from before the first signed build stay installable.
first=$(sed -n 's/^first_signed_build=//p' "$repository/packaging/linux/get-aurelia.sh")
release earlier "" none $((first - 1))
install_from earlier || { cat "$work/earlier/output" >&2; fail "an older release without a signature was not installed"; }
[ -e "$work/earlier/installed" ] || fail "the older release's installer did not run"
echo "get-aurelia.sh: all checks passed."
