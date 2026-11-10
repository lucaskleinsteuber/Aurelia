#!/bin/bash
# Checks an unpacked Linux server package on this Linux computer with synthetic data only:
# installation as a service, headless setup, approving a device, a library with a scan, power
# saving decisions, stopping Aurelia and starting it on a connection, restart, update over the
# existing installation, `aurelia update` from a local stand-in for GitHub Releases (python3) and
# uninstalling. With --exfat it also mounts
# a synthetic exFAT image through /etc/fstab (restored afterwards) to check that its files get
# no unstable identity and that the unplugged drive counts as unavailable. Everything it adds,
# including the server data, is removed at the end. It refuses to run where Aurelia is set up.
set -euo pipefail
package=$(CDPATH= cd -- "${1:?Give the unpacked package folder.}" && pwd)
exfat=false
[ "${2:-}" = --exfat ] && exfat=true
[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo)." >&2; exit 1; }
if [ -e /var/lib/aurelia/aurelia.db ]; then
  echo "Aurelia is already set up here; this test only runs on a computer without Aurelia data." >&2
  exit 1
fi

owner=linux-test-owner
password=Synthetic-Linux-Password-1
pin=2468
media=/srv/aurelia-linux-test
fstab_backup=""
release_server=""
api=http://127.0.0.1:43110

cleanup() {
  set +e
  [ -n "$release_server" ] && kill "$release_server" 2>/dev/null
  if [ -n "$fstab_backup" ]; then
    umount "$media/exfat" 2>/dev/null
    cp "$fstab_backup" /etc/fstab
    systemctl daemon-reload
  fi
  [ -x /usr/local/bin/aurelia ] && printf 'y\n' | aurelia uninstall --remove-data >/dev/null
  rm -rf "$media" "${fstab_backup:-}"
}
trap cleanup EXIT

step() { printf '\n== %s\n' "$*"; }
fail() { echo "FAILED: $*" >&2; exit 1; }
# The server allows only a few sign-ins a minute; a limited command waits and tries again.
as_owner() {
  local output
  for _ in 1 2 3; do
    if output=$(printf '%s\n%s\n' "$password" "$pin" | "$@" --username "$owner" 2>&1); then
      printf '%s\n' "$output"
      return 0
    fi
    grep -F rate_limited <<<"$output" >/dev/null || { printf '%s\n' "$output" >&2; return 1; }
    sleep 61
  done
  return 1
}
query() { sqlite3 -readonly /var/lib/aurelia/aurelia.db "$1"; }
# Reads all input, so a writer never fails on a closed pipe under pipefail.
has() { grep -F -- "$1" >/dev/null; }

step "Install"
"$package/install.sh"
systemctl is-active --quiet aurelia || fail "the service is not running"
for _ in $(seq 1 30); do aurelia status 2>/dev/null | has 'LAN access: disabled' && break; sleep 1; done
aurelia status | has 'LAN access: disabled' || fail "a new server must not be reachable from the network"
[ "$(stat -c '%U %a' /var/lib/aurelia)" = "aurelia 700" ] || fail "the data folder is not private to the aurelia user"
[ -x /usr/bin/ffmpeg ] && [ -x /usr/bin/ffprobe ] || fail "the installer did not provide ffmpeg"
for _ in $(seq 1 30); do curl -fsS "$api/api/v1/server/info" 2>/dev/null | has live-conversion-v1 && break; sleep 1; done
curl -fsS "$api/api/v1/server/info" | has live-conversion-v1 || fail "the service does not report live conversion"

step "Set up without a screen"
printf '%s\n%s\n' "$owner" "$password" | aurelia setup --name "Linux Test" | tee /dev/stderr | has 'Verification fingerprint' \
  || fail "setup did not turn on network access"
ss -ltn | has ':43111 ' || fail "HTTPS for other devices is not listening"
[ "$(query "SELECT COUNT(*) FROM DeviceSessions WHERE RevokedAt IS NULL;")" = 0 ] || fail "setup left a session behind"

step "Approve a device that shows a code"
pairing=$(curl -fsS "$api/api/v1/auth/device-pairings" -H 'Content-Type: application/json' -d '{"deviceName":"Linux Test Device"}')
code=$(jq -r .code <<<"$pairing"); id=$(jq -r .id <<<"$pairing"); secret=$(jq -r .secret <<<"$pairing")
printf '%s\n%s\n%s\n' "$owner" "$password" "$pin" | aurelia approve "$code" --yes | has 'is approved' || fail "approval failed"
sleep 6
state=$(curl -fsS "$api/api/v1/auth/device-pairings/$id/status" -H 'Content-Type: application/json' -d "{\"secret\":\"$secret\"}")
[ "$(jq -r .state <<<"$state")" = approved ] && [ "$(jq -r '.authentication.token | length' <<<"$state")" -gt 0 ] \
  || fail "the device did not receive its sign-in"

step "Add and scan a synthetic library"
mkdir -p "$media/ext/Synthetic Movie (2020)"
truncate -s 2M "$media/ext/Synthetic Movie (2020)/Synthetic Movie (2020).mkv"
chmod -R a+rX "$media"
as_owner aurelia library add --kind movies --path "$media/ext" --name "Linux Test Movies" | has 'Added' || fail "library add failed"
as_owner aurelia library scan --all >/dev/null || fail "the scan failed"
[ "$(query "SELECT COUNT(*) FROM MediaItems WHERE SourcePath LIKE '$media/ext/%';")" -ge 1 ] || fail "the synthetic movie was not found"
query "SELECT FileSystemIdentity FROM MediaItems WHERE SourcePath LIKE '$media/ext/%';" | grep -E '^linux:' >/dev/null \
  || fail "a file on ext4 has no lasting identity"

if $exfat; then
  step "exFAT drive through /etc/fstab"
  fstab_backup=$(mktemp)
  cp /etc/fstab "$fstab_backup"
  truncate -s 64M "$media/exfat.img"
  mkfs.exfat -q "$media/exfat.img" >/dev/null 2>&1 || mkfs.exfat "$media/exfat.img" >/dev/null
  mkdir -p "$media/exfat"
  printf '%s %s exfat loop,nofail,uid=0,gid=0,fmask=0022,dmask=0022 0 0\n' "$media/exfat.img" "$media/exfat" >> /etc/fstab
  systemctl daemon-reload
  mount "$media/exfat"
  mkdir -p "$media/exfat/Another Movie (2021)"
  truncate -s 2M "$media/exfat/Another Movie (2021)/Another Movie (2021).mkv"
  as_owner aurelia library add --kind movies --path "$media/exfat" --name "Linux Test exFAT" | has 'Added' || fail "exFAT library add failed"
  as_owner aurelia library scan --all >/dev/null || fail "the exFAT scan failed"
  [ "$(query "SELECT COUNT(*) FROM MediaItems WHERE SourcePath LIKE '$media/exfat/%';")" -ge 1 ] || fail "the exFAT movie was not found"
  [ "$(query "SELECT COUNT(*) FROM MediaItems WHERE SourcePath LIKE '$media/exfat/%' AND FileSystemIdentity IS NOT NULL;")" = 0 ] \
    || fail "a file on exFAT got an identity that changes at every mount"
  umount "$media/exfat"
  for _ in $(seq 1 40); do
    [ "$(query "SELECT Availability FROM LibraryRoots WHERE Path = '$media/exfat';")" = Unavailable ] && break
    sleep 1
  done
  [ "$(query "SELECT Availability FROM LibraryRoots WHERE Path = '$media/exfat';")" = Unavailable ] \
    || fail "an unplugged drive's empty mount point counts as available"
  [ "$(query "SELECT COUNT(*) FROM MediaItems WHERE SourcePath LIKE '$media/exfat/%';")" -ge 1 ] \
    || fail "titles of the unplugged drive were lost"
  mount "$media/exfat"
  for _ in $(seq 1 40); do
    [ "$(query "SELECT Availability FROM LibraryRoots WHERE Path = '$media/exfat';")" = Available ] && break
    sleep 1
  done
  [ "$(query "SELECT Availability FROM LibraryRoots WHERE Path = '$media/exfat';")" = Available ] \
    || fail "the reconnected drive did not come back"
fi

step "Power saving decisions (without sleeping)"
settings=/var/lib/aurelia/sleep-settings
systemctl is-enabled --quiet aurelia-autosleep.timer || fail "the power check must run after installing"
grep -Fx 'MODE=off' "$settings" >/dev/null || fail "power saving must start off"
aurelia sleep on --idle 5 --awake 17:00-23:30 >/dev/null
grep -Fx 'MODE=sleep' "$settings" >/dev/null || fail "sleep mode did not turn on"
grep -Fx 'IDLE_MINUTES=5' "$settings" >/dev/null || fail "sleep settings were not saved"
grep -Fx 'AWAKE_FROM=17:00' "$settings" >/dev/null || fail "awake hours were not saved"
[ "$(stat -c %U:%a "$settings")" = aurelia:600 ] || fail "the server must own its power settings"
aurelia sleep on --awake off >/dev/null
grep -Fx 'AWAKE_FROM=' "$settings" >/dev/null || fail "awake hours were not removed"
grep -Fx 'IDLE_MINUTES=5' "$settings" >/dev/null || fail "removing awake hours lost the idle time"
dry() { AURELIA_AUTOSLEEP_DRY_RUN=1 AURELIA_AUTOSLEEP_STATE="$media/sleep-state" /opt/aurelia/aurelia-autosleep; }
dry | has 'awake: signed in over SSH' || [ -z "${SSH_CONNECTION:-}" ] || fail "an SSH session must keep the computer awake"
if [ -z "${SSH_CONNECTION:-}" ]; then
  date +%s > /var/lib/aurelia/sleep-ready
  dry | has 'sleep until a Wake-on-LAN call' || fail "an ended sleep timer did not lead to sleep"
  rm -f /var/lib/aurelia/sleep-ready
  # An app left open keeps its sync connection, but only real use keeps the computer awake.
  if awk '{ exit !($1 <= 0.5) }' /proc/loadavg; then
    echo $(( $(date +%s) - 600 )) > "$media/sleep-state/last-active"
    echo $(( $(date +%s) - 600 )) > /var/lib/aurelia/last-use
    dry | has 'sleep until a Wake-on-LAN call' || fail "an app nobody uses must not keep the computer awake"
    date +%s > /var/lib/aurelia/last-use
    dry | has 'awake: used 0 minutes ago' || fail "using Aurelia must keep the computer awake"
  fi
  rm -f /var/lib/aurelia/last-use
fi
# A line the server's user could write must never run as root.
printf 'MODE=sleep\nIDLE_MINUTES=$(touch /tmp/aurelia-injected)\n' > "$settings"
dry >/dev/null
[ ! -e /tmp/aurelia-injected ] || fail "power settings were run as a script"

step "Stop only Aurelia and start it again when a device connects"
aurelia sleep server --idle 5 >/dev/null
grep -Fx 'MODE=stop' "$settings" >/dev/null || fail "stopping only Aurelia was not saved"
date +%s > /var/lib/aurelia/sleep-ready
/opt/aurelia/aurelia-autosleep
! systemctl is-active --quiet aurelia || fail "Aurelia did not stop after a sleep timer"
systemctl is-active --quiet aurelia-start.socket || fail "nothing waits for devices while Aurelia is stopped"
aurelia status | has 'stopped to save power' || fail "the status does not say that Aurelia is stopped"
curl -ks --max-time 3 https://127.0.0.1:43111/api/v1/server/info >/dev/null || true
for _ in $(seq 1 30); do aurelia status 2>/dev/null | has 'LAN access: enabled' && break; sleep 1; done
aurelia status | has 'LAN access: enabled' || fail "a connecting device did not start Aurelia"
! systemctl is-active --quiet aurelia-start.socket || fail "the start socket stayed open next to Aurelia"
aurelia sleep off >/dev/null
grep -Fx 'MODE=off' "$settings" >/dev/null || fail "power saving did not turn off"
dry | has 'power saving is off' || fail "the power check ignored that it is off"
[ "$(systemctl is-enabled aurelia-wake-on-lan.service 2>/dev/null)" = enabled ] || fail "Wake-on-LAN must stay allowed"

step "Restart keeps everything"
systemctl restart aurelia
for _ in $(seq 1 60); do aurelia status 2>/dev/null | has 'LAN access: enabled' && break; sleep 1; done
aurelia status | has 'LAN access: enabled' || fail "network access was lost after a restart"

step "Update over the installation"
"$package/install.sh" | has 'updated' || fail "the update was not recognized"
for _ in $(seq 1 60); do aurelia status 2>/dev/null | has 'LAN access: enabled' && break; sleep 1; done
[ "$(query "SELECT COUNT(*) FROM Users;")" -ge 1 ] || fail "the update lost the accounts"
as_owner aurelia library list | has 'Linux Test Movies' || fail "the update lost the library"

step "Update from a release, also while power saving stopped Aurelia"
command -v python3 >/dev/null 2>&1 || fail "python3 is needed for the stand-in release server"
release=$media/release
arch=$(cat "$package/ARCHITECTURE")
installed_build=$(sed -n 's/.*(\([0-9][0-9]*\)).*/\1/p' /opt/aurelia/VERSION)
next_build=$((installed_build + 1))
# The stand-in release is signed with a throwaway key, at a build that needs a signature.
first_signed_build=$(sed -n 's/^first_signed_build=//p' /usr/local/bin/aurelia)
[ "$next_build" -ge "$first_signed_build" ] || next_build=$first_signed_build
. "$(dirname -- "$0")/synthetic-signing.sh"
mkdir -p "$release/key"
signing_key=$(synthetic_signing_key "$release/key")
sign_sums() { synthetic_sign "$release/key" "$release/files/SHA256SUMS" "Aurelia Server 9.9.9 ($next_build)"; }
folder="Aurelia-Server-9.9.9-linux-$arch"
archive="Aurelia-Server-9.9.9-$next_build-linux-$arch.tar.gz"
mkdir -p "$release/files" "$release/repos/test/aurelia"
cp -R "$package" "$release/$folder"
echo "9.9.9 ($next_build)" > "$release/$folder/VERSION"
tar -czf "$release/files/$archive" -C "$release" "$folder"
rm -rf "${release:?}/$folder"
# Like GitHub's list: a draft with a higher build must be ignored. $2 = unsigned leaves the
# signature out.
offer() {
  jq -n --arg files http://127.0.0.1:43180/files --arg name "$1" --arg draft "Aurelia-Server-9.9.9-$((next_build + 5))-linux-$arch.tar.gz" '
    [ { draft: true, prerelease: false, assets: [ { name: $draft, url: "\($files)/\($draft)" },
        { name: "SHA256SUMS", url: "\($files)/SHA256SUMS" } ] },
      { draft: false, prerelease: false, assets: [ { name: $name, url: "\($files)/\($name)" },
        { name: "SHA256SUMS", url: "\($files)/SHA256SUMS" },
        { name: "SHA256SUMS.minisig", url: "\($files)/SHA256SUMS.minisig" } ] } ]' > "$release/repos/test/aurelia/releases"
  if [ "${2:-}" = unsigned ]; then
    jq '(.[1].assets) |= map(select(.name != "SHA256SUMS.minisig"))' "$release/repos/test/aurelia/releases" \
      > "$release/releases.unsigned" && mv "$release/releases.unsigned" "$release/repos/test/aurelia/releases"
  fi
}
offer "$archive"
python3 -I -m http.server 43180 --bind 127.0.0.1 --directory "$release" >/dev/null 2>&1 &
release_server=$!
for _ in $(seq 1 20); do curl -fs http://127.0.0.1:43180/files/ >/dev/null && break; sleep 0.5; done
update() {
  AURELIA_UPDATE_API=http://127.0.0.1:43180 AURELIA_UPDATE_REPOSITORY=test/aurelia AURELIA_UPDATE_SIGNING_KEY="$signing_key" \
    aurelia update "$@"
}
before=$(cat /opt/aurelia/VERSION)
status=/var/lib/aurelia/update-status
systemctl is-enabled --quiet aurelia-update-request.path && systemctl is-enabled --quiet aurelia-update-check.timer \
  || fail "updates requested in the app are not watched for"
# Requests from the app are answered here against the stand-in, not by the service against GitHub.
systemctl stop aurelia-update-request.path

printf '0%.0s' $(seq 1 64) > "$release/files/SHA256SUMS"
printf '  ./%s\n' "$archive" >> "$release/files/SHA256SUMS"
sign_sums
{ update --yes 2>&1 || true; } | has 'does not match its checksum' || fail "a download with a wrong checksum was not refused"
[ "$(cat /opt/aurelia/VERSION)" = "$before" ] || fail "a refused download changed the installation"
grep -Fx 'STATE=failed' "$status" >/dev/null && grep -F 'MESSAGE=The download does not match' "$status" >/dev/null \
  || fail "the app is not told why the update failed"
[ "$(stat -c %U:%a "$status")" = aurelia:600 ] || fail "the server must own the update status"
(cd "$release/files" && sha256sum "./$archive" > SHA256SUMS)
# A correct checksum list counts only with the owner's signature.
{ update --yes 2>&1 || true; } | has 'not signed by the owner' || fail "a release with a stale signature was installed"
offer "$archive" unsigned
{ update --yes 2>&1 || true; } | has 'not signed by the owner' || fail "a release without a signature was installed"
[ "$(cat /opt/aurelia/VERSION)" = "$before" ] || fail "an unsigned release changed the installation"
grep -F 'MESSAGE=The release is not signed' "$status" >/dev/null || fail "the app is not told that the release is unsigned"
offer "$archive"
sign_sums

touch /var/lib/aurelia/update-check-requested
update --from-app >/dev/null
[ ! -e /var/lib/aurelia/update-check-requested ] || fail "the check request from the app stayed"
grep -Fx 'STATE=idle' "$status" >/dev/null && grep -Fx "NEWEST_BUILD=$next_build" "$status" >/dev/null \
  || fail "the app is not told about the newer release"
[ "$(cat /opt/aurelia/VERSION)" = "$before" ] || fail "a check requested in the app changed the installation"

update --check | has "Newest:    Aurelia Server 9.9.9 ($next_build)" || fail "the check did not find the newer release"
[ "$(cat /opt/aurelia/VERSION)" = "$before" ] || fail "checking for an update changed the installation"
printf 'n\n' | update | has 'Nothing was changed' || fail "declining the update did not stop it"

aurelia sleep server --idle 5 >/dev/null
date +%s > /var/lib/aurelia/sleep-ready
/opt/aurelia/aurelia-autosleep
! systemctl is-active --quiet aurelia || fail "Aurelia did not stop before the update"
touch /var/lib/aurelia/update-requested
update --from-app | has 'updated' || fail "the update requested in the app failed"
[ ! -e /var/lib/aurelia/update-requested ] || fail "the update request from the app stayed"
grep -Fx 'STATE=idle' "$status" >/dev/null && grep -Fx "TARGET_BUILD=$next_build" "$status" >/dev/null \
  || fail "the app is not told that the update finished"
[ "$(cat /opt/aurelia/VERSION)" = "9.9.9 ($next_build)" ] || fail "the release was not installed"
systemctl is-active --quiet aurelia || fail "Aurelia did not start after the update"
for _ in $(seq 1 60); do aurelia status 2>/dev/null | has 'LAN access: enabled' && break; sleep 1; done
aurelia status | has 'LAN access: enabled' || fail "network access was lost by the update"
grep -Fx 'MODE=stop' /var/lib/aurelia/sleep-settings >/dev/null || fail "the update changed the power settings"
as_owner aurelia library list | has 'Linux Test Movies' || fail "the update from the release lost the library"
aurelia sleep off >/dev/null
update --check | has 'up to date' || fail "the installed release is not recognized as current"

offer "Aurelia-Server-1.0.0-$installed_build-linux-$arch.tar.gz"
update --yes | has 'not downgraded' || fail "an older release was not refused"
[ "$(cat /opt/aurelia/VERSION)" = "9.9.9 ($next_build)" ] || fail "an older release replaced the newer one"
systemctl start aurelia-update-request.path

step "Uninstall"
printf 'y\n' | aurelia uninstall --remove-data | has 'deleted' || fail "uninstall did not remove the test data"
[ ! -e /opt/aurelia ] && [ ! -e /var/lib/aurelia ] && [ ! -e /etc/systemd/system/aurelia.service ] \
  && [ ! -e /etc/systemd/system/aurelia-autosleep.timer ] && [ ! -e /etc/aurelia-autosleep.conf ] \
  && [ ! -e /etc/systemd/system/aurelia-update-request.path ] && [ ! -e /etc/systemd/system/aurelia-update-check.timer ] \
  || fail "uninstall left files behind"
! id aurelia >/dev/null 2>&1 || fail "uninstall left the aurelia user behind"
echo
echo "Linux server package checks passed."
