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
echo "aurelia-autosleep decisions: all checks passed."
