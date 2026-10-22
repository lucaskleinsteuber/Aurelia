#!/bin/bash
# Checks an unpacked Linux server package on this Linux computer with synthetic data only:
# installation as a service, headless setup, approving a device, a library with a scan,
# restart, update over the existing installation and uninstalling. With --exfat it also mounts
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
api=http://127.0.0.1:43110

cleanup() {
  set +e
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

step "Sleep mode decisions (without sleeping)"
aurelia sleep on --idle 5 --awake 17:00-23:30 >/dev/null
systemctl is-enabled --quiet aurelia-autosleep.timer || fail "sleep mode did not turn on"
grep -F 'IDLE_MINUTES=5' /etc/aurelia-autosleep.conf >/dev/null || fail "sleep settings were not saved"
dry() { AURELIA_AUTOSLEEP_DRY_RUN=1 AURELIA_AUTOSLEEP_STATE="$media/sleep-state" /opt/aurelia/aurelia-autosleep; }
dry | has 'awake: signed in over SSH' || [ -z "${SSH_CONNECTION:-}" ] || fail "an SSH session must keep the server awake"
if [ -z "${SSH_CONNECTION:-}" ]; then
  date +%s > /var/lib/aurelia/sleep-ready
  dry | has 'sleep until' || fail "an ended sleep timer did not lead to sleep"
  rm -f /var/lib/aurelia/sleep-ready
fi
aurelia sleep off >/dev/null
! systemctl is-enabled --quiet aurelia-autosleep.timer || fail "sleep mode did not turn off"
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

step "Uninstall"
printf 'y\n' | aurelia uninstall --remove-data | has 'deleted' || fail "uninstall did not remove the test data"
[ ! -e /opt/aurelia ] && [ ! -e /var/lib/aurelia ] && [ ! -e /etc/systemd/system/aurelia.service ] \
  && [ ! -e /etc/systemd/system/aurelia-autosleep.timer ] && [ ! -e /etc/aurelia-autosleep.conf ] \
  || fail "uninstall left files behind"
! id aurelia >/dev/null 2>&1 || fail "uninstall left the aurelia user behind"
echo
echo "Linux server package checks passed."
