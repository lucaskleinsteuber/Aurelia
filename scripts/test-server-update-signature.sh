#!/bin/bash
# Checks the signature check that `aurelia update`, the one-line installer and the Docker build
# share: all three carry the same check, the owner's key (the Linux app's) and no unsigned build
# exception, and the check accepts only a valid signature by that key. Synthetic files and a
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
for script in "${scripts[@]}"; do
  function_of "$script" | cmp -s - "$work/check.sh" || fail "$script checks signatures differently"
  [ "$(value_of "$script" signing_public_key)" = "$app_key" ] || fail "$script does not carry the owner's key"
  # All three scripts always require the owner's signature, old builds included (audit LNX-PKG-002).
  first=$(value_of "$script" first_signed_build)
  [ -z "$first" ] && ! grep -q 'first_signed_build' "$repository/$script" \
    || fail "$script lets some builds go unsigned"
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
synthetic_signing_key "$work/other" >/dev/null
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

# Exercise `aurelia update` against missing/unreadable VERSION and unsigned pre-153 builds (audit LNX-PKG-002),
# plus CLI option parsing fixes (audit LNX-PKG-017), in an isolated copy without root.
case "$(uname -m)" in
  x86_64|amd64) host_arch=x64 ;;
  aarch64|arm64) host_arch=arm64 ;;
  *) host_arch="" ;;
esac
if [ -n "$host_arch" ]; then
  mkdir -p "$work/cli/bin" "$work/cli/install" "$work/cli/etc" "$work/cli/data" "$work/cli/api/repos/test/aurelia/releases"
  touch "$work/cli/etc/test-update-source"
  cp "$repository/packaging/linux/aurelia-sleep-settings" "$work/cli/install/aurelia-sleep-settings"
  sed -e "s|^install_root=/opt/aurelia$|install_root=$work/cli/install|" \
      -e "s|^data_dir=/var/lib/aurelia$|data_dir=$work/cli/data|" \
      -e "s|/etc/aurelia/test-update-source|$work/cli/etc/test-update-source|g" \
      -e "s|^token_file=/etc/aurelia/github-token$|token_file=$work/cli/etc/github-token|" \
      -e "s|^channel_file=/etc/aurelia/update-channel$|channel_file=$work/cli/etc/update-channel|" \
      "$repository/packaging/linux/aurelia" > "$work/cli/aurelia"
  chmod +x "$work/cli/aurelia"
  cat > "$work/cli/bin/id" <<'STUB'
#!/bin/bash
[ "${1:-}" = -u ] && { echo 0; exit 0; }
exit 1
STUB
  printf '#!/bin/bash\nexit 1\n' > "$work/cli/bin/systemctl"
  cat > "$work/cli/bin/curl" <<STUB
#!/bin/bash
out=""
url=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out=\$2; shift 2 ;;
    *) url=\$1; shift ;;
  esac
done
path="\${url#http://standin}"
if [ -f "$work/cli/api\$path" ]; then
  cp "$work/cli/api\$path" "\$out"
  printf '200'
else
  printf '404'
fi
STUB
  chmod +x "$work/cli/bin/id" "$work/cli/bin/systemctl" "$work/cli/bin/curl"

  # Option without a value must fail with a message rather than exiting silently under set -e.
  if PATH="$work/cli/bin:$PATH" bash "$work/cli/aurelia" setup --name >"$work/cli/out" 2>&1; then
    fail "setup --name without a value must fail"
  fi
  grep -F -- '--name needs a value' "$work/cli/out" >/dev/null || fail "missing error for setup --name without value: $(cat "$work/cli/out")"
  if PATH="$work/cli/bin:$PATH" bash "$work/cli/aurelia" sleep on --idle >"$work/cli/out" 2>&1; then
    fail "sleep --idle without a value must fail"
  fi
  grep -F -- '--idle needs a number of minutes' "$work/cli/out" >/dev/null || fail "missing error for sleep --idle without value: $(cat "$work/cli/out")"

  # Leading-zero decimal values like 09 must not fail as invalid octal (audit LNX-PKG-017).
  # Without /sys/power/state or runuser the command fails later, never at the --idle validation.
  if PATH="$work/cli/bin:$PATH" bash "$work/cli/aurelia" sleep server --idle 09 >"$work/cli/out" 2>&1; then
    :
  fi
  if grep -F -- '--idle needs a number of minutes' "$work/cli/out" >/dev/null; then
    fail "sleep --idle 09 was rejected as octal: $(cat "$work/cli/out")"
  fi

  # Stopped manually (neither aurelia nor aurelia-start.socket active) must report stopped immediately.
  if PATH="$work/cli/bin:$PATH" bash "$work/cli/aurelia" pair >"$work/cli/out" 2>&1; then
    fail "ensure_running must fail when aurelia is stopped"
  fi
  grep -F 'Aurelia Server is stopped' "$work/cli/out" >/dev/null || fail "ensure_running did not explain manual stop: $(cat "$work/cli/out")"

  # Offer an unsigned build 100 (< 153) via the stand-in API.
  printf '%064d  ./Aurelia-Server-1.0.0-100-linux-%s.tar.gz\n' 0 "$host_arch" > "$work/cli/api/SHA256SUMS"
  jq -n --arg name "Aurelia-Server-1.0.0-100-linux-$host_arch.tar.gz" \
    '{draft: false, prerelease: false, assets: [
      {name: $name, url: "http://standin/nonexistent.tar.gz"},
      {name: "SHA256SUMS", url: "http://standin/SHA256SUMS"}]}' \
    > "$work/cli/api/repos/test/aurelia/releases/latest"

  # 1) Missing VERSION must fail closed (never skip downgrade protection).
  if PATH="$work/cli/bin:$PATH" AURELIA_UPDATE_API="http://standin" \
    AURELIA_UPDATE_REPOSITORY=test/aurelia AURELIA_UPDATE_LOCK="$work/cli/lock" \
    bash "$work/cli/aurelia" update --yes >"$work/cli/out" 2>&1; then
    fail "aurelia update proceeded without VERSION"
  fi
  grep -F 'Cannot read the installed build' "$work/cli/out" >/dev/null \
    || fail "missing unreadable-VERSION error: $(cat "$work/cli/out")"

  # 2) Corrupted/unparseable VERSION must also fail closed.
  printf 'corrupted\n' > "$work/cli/install/VERSION"
  if PATH="$work/cli/bin:$PATH" AURELIA_UPDATE_API="http://standin" \
    AURELIA_UPDATE_REPOSITORY=test/aurelia AURELIA_UPDATE_LOCK="$work/cli/lock" \
    bash "$work/cli/aurelia" update --yes >"$work/cli/out" 2>&1; then
    fail "aurelia update proceeded with unreadable VERSION"
  fi
  grep -F 'Cannot read the installed build' "$work/cli/out" >/dev/null \
    || fail "missing corrupted-VERSION error: $(cat "$work/cli/out")"

  # 3) Valid older VERSION + unsigned build 100 (< 153) must be refused as unsigned.
  printf '0.9.0 (50)\n' > "$work/cli/install/VERSION"
  if PATH="$work/cli/bin:$PATH" AURELIA_UPDATE_API="http://standin" \
    AURELIA_UPDATE_REPOSITORY=test/aurelia AURELIA_UPDATE_LOCK="$work/cli/lock" \
    bash "$work/cli/aurelia" update --yes >"$work/cli/out" 2>&1; then
    fail "aurelia update accepted an unsigned build < 153"
  fi
  grep -F 'not signed by the owner' "$work/cli/out" >/dev/null \
    || fail "unsigned build < 153 was not refused as unsigned: $(cat "$work/cli/out")"
fi
echo "Server update signatures: all checks passed."
