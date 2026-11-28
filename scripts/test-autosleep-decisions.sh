#!/bin/bash
# Checks tarven-autosleep's decisions on this Linux computer without root, systemd or a server:
# systemctl and ss are replaced by stand-ins and everything lives in a temporary folder. Only
# dry runs are made, so the computer never sleeps and no service is touched.
set -euo pipefail
repository=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/data" "$work/state"

# systemctl is-active succeeds only for the units named in ACTIVE.
cat > "$work/bin/systemctl" <<'STUB'
#!/bin/bash
[ "$1" = is-active ] || exit 0
shift
[ "${1:-}" = --quiet ] && shift
for unit in "$@"; do case " $ACTIVE " in *" $unit "*) exit 0 ;; esac; done
exit 3
STUB
printf '#!/bin/bash\nexit 0\n' > "$work/bin/ss"
printf '#!/bin/bash\nexit 0\n' > "$work/bin/sshd"
printf '#!/bin/bash\nexit 0\n' > "$work/bin/loginctl"
chmod +x "$work/bin/systemctl" "$work/bin/ss" "$work/bin/sshd" "$work/bin/loginctl"
printf 'MODE=sleep\nIDLE_MINUTES=15\n' > "$work/data/sleep-settings"

decide() {
  local active=$1
  shift
  PATH="${DECIDE_EXTRA_BIN:+$DECIDE_EXTRA_BIN:}$work/bin:$PATH" ACTIVE="tarven $active" TARVEN_DATA_DIR="$work/data" \
    TARVEN_SLEEP_SETTINGS_LIBRARY="$repository/packaging/linux/tarven-sleep-settings" \
    TARVEN_AUTOSLEEP_DRY_RUN=1 TARVEN_AUTOSLEEP_STATE="$work/state" \
    bash "$repository/packaging/linux/tarven-autosleep" "$@"
}
fail() { echo "FAIL: $*" >&2; exit 1; }

date +%s > "$work/data/sleep-ready"
decide "" | grep -F 'A sleep timer ended' >/dev/null || fail "an ended sleep timer must lead to sleep"
for unit in tarven-update-request.service tarven-update-check.service; do
  decide "$unit" | grep -Fx 'awake: updating' >/dev/null || fail "an ended sleep timer must not interrupt $unit"
done
[ -e "$work/data/sleep-ready" ] || fail "the sleep timer's signal must wait for the next check"

# Shut-down mode turns the computer off where sleep mode would put it to sleep.
printf 'MODE=shutdown\nIDLE_MINUTES=15\nWAKE_ON_ACCESS=on\n' > "$work/data/sleep-settings"
date +%s > "$work/data/sleep-ready"
decide "" | grep -F 'turn off until a Wake-on-LAN call: A sleep timer ended' >/dev/null \
  || fail "shut-down mode must turn the computer off after an ended sleep timer"
rm -f "$work/data/sleep-ready"

# With AFTER_SLEEP_TIMER=off an ended sleep timer changes nothing.
printf 'MODE=sleep\nIDLE_MINUTES=60\nAFTER_SLEEP_TIMER=off\n' > "$work/data/sleep-settings"
date +%s > "$work/data/sleep-ready"
date +%s > "$work/state/last-active"
decide "" | grep -F 'A sleep timer ended' >/dev/null && fail "a switched off sleep-timer rule must not power down"
rm -f "$work/data/sleep-ready"

# Woken (by a stray packet, perhaps) and nobody used Tarven since: it sleeps again after five
# minutes instead of a whole idle period; once someone used it, the idle period counts again.
printf 'MODE=sleep\nIDLE_MINUTES=60\n' > "$work/data/sleep-settings"
woken=$(( $(date +%s) - 400 ))
echo "$woken" > "$work/state/last-active"
echo "$woken" > "$work/state/woke"
decide "" | grep -F 'Woken but unused for 5 minutes' >/dev/null || fail "an unused wake must end after five minutes"
echo $(( woken + 60 )) > "$work/data/last-use"
decide "" | grep -F 'awake: used' >/dev/null || fail "a wake someone used must keep the idle period"
rm -f "$work/data/last-use" "$work/state/woke"

# The night the clocks go forward: 02:30 does not exist in Berlin on 28.03.2027. A stand-in for
# date makes it 00:30 that night; the computer must still sleep and wake at 03:30.
real_date=$(command -v date)
mkdir -p "$work/dst"
cat > "$work/dst/date" <<STUB
#!/bin/bash
[ "\$*" = +%s ] && exec "$real_date" -d '2027-03-28 00:30' +%s
arguments=()
for argument in "\$@"; do argument=\${argument//today/2027-03-28}; arguments+=("\${argument//tomorrow/2027-03-29}"); done
exec "$real_date" "\${arguments[@]}"
STUB
chmod +x "$work/dst/date"
printf 'MODE=sleep\nIDLE_MINUTES=15\nAWAKE_FROM=02:30\nAWAKE_UNTIL=06:00\n' > "$work/data/sleep-settings"
TZ=Europe/Berlin touch -d '2027-03-28 00:25' "$work/data/sleep-ready"
spring=$(PATH="$work/dst:$PATH" TZ=Europe/Berlin LC_ALL=C decide "") \
  || fail "the night the clocks go forward must not end the check with an error"
grep -F 'sleep until Sun 03:30 or a Wake-on-LAN call' <<<"$spring" >/dev/null \
  || fail "the night the clocks go forward must wake at 03:30, not: $spring"
# Asked from an app to turn off now: done whatever MODE says, even with power saving off and
# someone signed in over SSH; an unknown word or a link is ignored; an update finishes first.
printf 'MODE=off\nIDLE_MINUTES=15\n' > "$work/data/sleep-settings"
echo shutdown > "$work/data/power-now"
decide "" --now | grep -F 'turn off until a Wake-on-LAN call: Asked from an app' >/dev/null \
  || fail "a request to turn off now must turn the computer off"
echo sleep > "$work/data/power-now"
decide "" --now | grep -F 'sleep until a Wake-on-LAN call: Asked from an app' >/dev/null \
  || fail "a request to sleep now must put the computer to sleep"
echo stop > "$work/data/power-now"
decide "" --now | grep -F 'stop Tarven until a device connects: Asked from an app' >/dev/null \
  || fail "a request to stop now must stop only Tarven"
echo reboot > "$work/data/power-now"
[ -z "$(decide "" --now)" ] || fail "an unknown request must do nothing"
echo shutdown > "$work/data/power-now"
[ -z "$(decide tarven-update-request.service --now)" ] || fail "a request must not interrupt an update"
rm -f "$work/data/power-now"
echo shutdown > "$work/elsewhere"
ln -s "$work/elsewhere" "$work/data/power-now"
[ -z "$(decide "" --now)" ] || fail "a linked request file must be ignored"
rm -f "$work/data/power-now"
[ -z "$(decide "" --now)" ] || fail "without a request --now must do nothing"

mkdir "$work/data/power-now"
[ -z "$(decide "" --now)" ] || fail "a folder at the request's name must do nothing but be removed"
rmdir "$work/data/power-now"

# An empty last-active (a cut write) must not end every later check with an error (audit S-X21).
rm -f "$work/data/sleep-ready" "$work/state/woke"
printf 'MODE=sleep\nIDLE_MINUTES=15\n' > "$work/data/sleep-settings"
: > "$work/state/last-active"
decide "" >/dev/null || fail "an empty last-active must not stop the check"

# A scan or metadata job the server reports keeps the computer on, even after an ended sleep timer
# (audit LNX-PKG-012); its analysis note alone does not (audit B-4).
echo $(( $(date +%s) - 3600 )) > "$work/state/last-active"
echo keepawake > "$work/data/work"
decide "" | grep -Fx 'awake: in use' >/dev/null || fail "a scan the server reports must keep the computer on"
date +%s > "$work/data/sleep-ready"
decide "" | grep -Fx 'awake: in use' >/dev/null || fail "an ended sleep timer must not interrupt an active scan/keepawake job"
[ -e "$work/data/sleep-ready" ] || fail "the sleep timer signal must stay while keepawake work runs"
rm -f "$work/data/sleep-ready"
echo $(( $(date +%s) - 3600 )) > "$work/state/last-active"
echo analysis > "$work/data/work"
touch -d '10 minutes ago' "$work/data/work"
decide "" | grep -F 'Unused for 15 minutes' >/dev/null || [ "$(awk '{ print ($1 > 0.5) }' /proc/loadavg)" = 1 ] \
  || fail "an old work note must not count"
rm -f "$work/data/work"

# With MODE=stop and Tarven already stopped behind tarven-start.socket, --now must still consume
# power-now rather than exiting early and causing systemd path unit start-limit-hit (audit LNX-PKG-007).
printf 'MODE=stop\nIDLE_MINUTES=15\n' > "$work/data/sleep-settings"
echo shutdown > "$work/data/power-now"
PATH="$work/bin:$PATH" ACTIVE="tarven-start.socket" TARVEN_DATA_DIR="$work/data" \
  TARVEN_SLEEP_SETTINGS_LIBRARY="$repository/packaging/linux/tarven-sleep-settings" \
  TARVEN_AUTOSLEEP_DRY_RUN=1 TARVEN_AUTOSLEEP_STATE="$work/state" \
  bash "$repository/packaging/linux/tarven-autosleep" --now \
  | grep -F 'turn off until a Wake-on-LAN call: Asked from an app' >/dev/null \
  || fail "--now must still process power-now when MODE=stop and tarven-start.socket is active"
rm -f "$work/data/power-now"

# Custom sshd port and local/remote loginctl sessions keep the computer awake (audit LNX-PKG-017).
mkdir -p "$work/ssh-bin"
cat > "$work/ssh-bin/sshd" <<'STUB'
#!/bin/bash
printf 'port 2222\n'
STUB
cat > "$work/ssh-bin/ss" <<'STUB'
#!/bin/bash
case "$*" in *":2222"*) printf '0 0 10.0.0.2:2222 10.0.0.3:50000\n' ;; esac
STUB
chmod +x "$work/ssh-bin/sshd" "$work/ssh-bin/ss"
printf 'MODE=sleep\nIDLE_MINUTES=15\n' > "$work/data/sleep-settings"
DECIDE_EXTRA_BIN="$work/ssh-bin" decide "" | grep -Fx 'awake: signed in over SSH' >/dev/null \
  || fail "an SSH session on a custom sshd port must keep the computer awake"

mkdir -p "$work/tty-bin"
cat > "$work/tty-bin/loginctl" <<'STUB'
#!/bin/bash
if [ "$1" = list-sessions ]; then
  printf '1 1000 user seat0 tty1\n'
elif [ "$1" = show-session ]; then
  case "$4" in
    Class) printf 'user\n' ;;
    State) printf 'active\n' ;;
    Remote) printf 'no\n' ;;
    Type) printf 'tty\n' ;;
  esac
fi
STUB
chmod +x "$work/tty-bin/loginctl"
DECIDE_EXTRA_BIN="$work/tty-bin" decide "" | grep -Fx 'awake: signed in on console' >/dev/null \
  || fail "an active local console session must keep the computer awake"

# During background analysis, unrelated high CPU load from other users still keeps the computer awake.
mkdir -p "$work/load-bin"
cat > "$work/load-bin/id" <<'STUB'
#!/bin/bash
[ "${1:-}" = -u ] && [ "${2:-}" = tarven ] && { echo 999; exit 0; }
exec /usr/bin/id "$@"
STUB
printf '#!/bin/bash\nprintf "999 80.0\\n1000 75.0\\n"\n' > "$work/load-bin/ps"
chmod +x "$work/load-bin/id" "$work/load-bin/ps"
echo $(( $(date +%s) - 3600 )) > "$work/state/last-active"
echo analysis > "$work/data/work"
DECIDE_EXTRA_BIN="$work/load-bin" decide "" | grep -Fx 'awake: in use' >/dev/null \
  || fail "unrelated user CPU load during analysis must keep the computer awake"
rm -f "$work/data/work"

echo "tarven-autosleep decisions: all checks passed."
