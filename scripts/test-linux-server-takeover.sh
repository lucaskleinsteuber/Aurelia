#!/bin/bash
# Checks that the Tarven installer takes an installation from before the rename (Aurelia Server)
# over in place: same server identity and data, the service user renamed, folders, settings and
# services under the new names, `aurelia` still a command. It runs on a Linux computer with Docker,
# entirely inside a throwaway Debian container with systemd: nothing on the computer itself is
# installed or changed, no port is published and no media is involved.
#   scripts/test-linux-server-takeover.sh <Aurelia-Server-…-linux-x64.tar.gz> <Tarven-Server-…-linux-x64.tar.gz>
set -euo pipefail
old=$(realpath "${1:?Give the Aurelia Server package (before the rename).}")
new=$(realpath "${2:?Give the Tarven Server package.}")
docker=(docker)
docker info >/dev/null 2>&1 || docker=(sudo -n docker)
name="tarven-takeover-test-$$"
cleanup() { "${docker[@]}" rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT

"${docker[@]}" run -d --name "$name" --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --tmpfs /run --tmpfs /run/lock docker.io/library/debian:trixie-slim \
  bash -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq systemd systemd-sysv \
    ca-certificates curl jq openssl libicu76 procps >/dev/null && exec /lib/systemd/systemd' >/dev/null
for _ in $(seq 1 180); do
  "${docker[@]}" exec "$name" test -x /lib/systemd/systemd 2>/dev/null \
    && "${docker[@]}" exec "$name" systemctl is-system-running --wait >/dev/null 2>&1 && break
  "${docker[@]}" exec "$name" systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded' && break
  sleep 2
done
# Not /tmp: Debian mounts a fresh tmpfs there when systemd starts.
"${docker[@]}" exec "$name" mkdir -p /root/takeover
"${docker[@]}" cp "$old" "$name:/root/takeover/old.tar.gz"
"${docker[@]}" cp "$new" "$name:/root/takeover/new.tar.gz"

"${docker[@]}" exec -i "$name" bash -s <<'TEST'
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
cd /root/takeover
mkdir old new
tar -xzf old.tar.gz -C old
tar -xzf new.tar.gz -C new
# Neither installer may download anything for this test; the optional packages are skipped.
apt-get() { return 1; }
export -f apt-get

echo "Installing Aurelia Server (before the rename)..."
(cd old/*/ && ./install.sh) >/root/takeover/old-install.log 2>&1 || { cat /root/takeover/old-install.log; fail "the Aurelia installer failed"; }
id aurelia >/dev/null || fail "no aurelia user"
uid=$(id -u aurelia)
for _ in $(seq 1 60); do [ -e /var/lib/aurelia/aurelia.db ] && break; sleep 1; done
[ -e /var/lib/aurelia/aurelia.db ] || fail "Aurelia created no database"
identity_before=$(/opt/aurelia/server/Aurelia.Server server identity 2>/dev/null | grep "^Server ID:" || true)
mkdir -p /etc/aurelia && printf 'beta\n' > /etc/aurelia/update-channel
printf 'synthetic' > /var/lib/aurelia/synthetic-marker
chown aurelia:aurelia /var/lib/aurelia/synthetic-marker
systemctl is-enabled --quiet aurelia || fail "aurelia.service was not enabled"

echo "Installing Tarven Server over it..."
(cd new/*/ && ./install.sh) >/root/takeover/new-install.log 2>&1 || { cat /root/takeover/new-install.log; fail "the Tarven installer failed"; }
grep -q "Taking over the Aurelia Server installation" /root/takeover/new-install.log || fail "no takeover was reported"

id tarven >/dev/null || fail "no tarven user"
[ "$(id -u tarven)" = "$uid" ] || fail "the service user changed its number"
! id aurelia >/dev/null 2>&1 || fail "the aurelia user is still there"
[ ! -e /var/lib/aurelia ] && [ ! -e /opt/aurelia ] && [ ! -e /etc/aurelia ] || fail "an old folder is left"
[ "$(cat /var/lib/tarven/synthetic-marker)" = synthetic ] || fail "the data folder was not taken over"
[ "$(stat -c %U /var/lib/tarven/synthetic-marker)" = tarven ] || fail "the data lost its owner"
[ "$(cat /etc/tarven/update-channel)" = beta ] || fail "the update channel was lost"
[ -e /var/lib/tarven/tarven.db ] && [ ! -e /var/lib/tarven/aurelia.db ] || fail "the database was not renamed"
systemctl is-active --quiet tarven || fail "tarven.service is not running"
[ ! -e /etc/systemd/system/aurelia.service ] || fail "aurelia.service is left"
[ "$(readlink /usr/local/bin/aurelia)" = /usr/local/bin/tarven ] || fail "aurelia is no longer a command"
# The server ID stays; a server that was never named shows the new default name "Tarven".
identity_after=$(/opt/tarven/server/Tarven.Server server identity 2>/dev/null | grep "^Server ID:" || true)
[ -n "$identity_before" ] && [ "$identity_before" = "$identity_after" ] || fail "the server identity changed: before [$identity_before] after [$identity_after]"
aurelia version >/dev/null || fail "the aurelia command does not work"
echo "PASS: the Aurelia installation was taken over as Tarven."
TEST
