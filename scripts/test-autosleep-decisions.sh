#!/bin/bash
# Checks aurelia-autosleep's decisions on this Linux computer without root, systemd or a server:
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
chmod +x "$work/bin/systemctl" "$work/bin/ss"
printf 'MODE=sleep\nIDLE_MINUTES=15\n' > "$work/data/sleep-settings"

decide() {
  PATH="$work/bin:$PATH" ACTIVE="aurelia $1" AURELIA_DATA_DIR="$work/data" \
    AURELIA_SLEEP_SETTINGS_LIBRARY="$repository/packaging/linux/aurelia-sleep-settings" \
    AURELIA_AUTOSLEEP_DRY_RUN=1 AURELIA_AUTOSLEEP_STATE="$work/state" \
    bash "$repository/packaging/linux/aurelia-autosleep"
}
fail() { echo "FAIL: $*" >&2; exit 1; }

date +%s > "$work/data/sleep-ready"
decide "" | grep -F 'A sleep timer ended' >/dev/null || fail "an ended sleep timer must lead to sleep"
for unit in aurelia-update-request.service aurelia-update-check.service; do
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

# Woken (by a stray packet, perhaps) and nobody used Aurelia since: it sleeps again after five
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
echo "aurelia-autosleep decisions: all checks passed."
