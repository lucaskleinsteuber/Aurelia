#!/bin/bash
# Checks the one-line installer packaging/linux/get-aurelia.sh against a local stand-in for GitHub
# Releases (file:// addresses) with synthetic packages, without root: id, systemctl and the
# aurelia command are stand-ins, and each package's install.sh only leaves a marker. Nothing on
# the computer is installed or changed. Needs curl, jq, tar and sha256sum.
set -euo pipefail
repository=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
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

# A release with one package. $1 names the case; $2 adds an entry outside the package folder.
release() {
  local name=$1 extra=${2:-} version=9.9.9 build=999
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
  jq -n --arg archive "$archive" --arg url "file://$dir/$archive" --arg sums "file://$dir/SHA256SUMS" \
    '[{draft: false, prerelease: false, assets: [{name: $archive, browser_download_url: $url}, {name: "SHA256SUMS", browser_download_url: $sums}]}]' \
    > "$dir/releases.json"
}
install_from() {
  PATH="$work/bin:$PATH" AURELIA_RELEASES_URL="file://$work/$1/releases.json" \
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
echo "get-aurelia.sh: all checks passed."
