#!/bin/bash
# Starts the installed native Aurelia package once on Wayland and once on X11 without
# interacting with either window. Synthetic XDG folders and a private D-Bus session isolate the
# owner's settings/keyring; no server, library or media is opened. Evidence stays in Local.
# Usage: scripts/test-linux-app-startup.sh --expected-version '1.0.0 (5)' [--verify-instance]
set -euo pipefail

wayland_window_proof() {
  python3 - "$1" "$2" <<'WAYLAND'
import pathlib, re, sys
states, toplevels = {}, {}
for line in pathlib.Path(sys.argv[1]).read_text(errors='replace').splitlines():
    match = re.search(r'xdg_wm_base[#@]\d+\.get_xdg_surface\(new id xdg_surface[#@](\d+), wl_surface[#@](\d+)\)', line)
    if match:
        states[match[1]] = dict(surface=match[2], lines=[line], configured=set(), acknowledged=False, attached=False, aurelia=False)
        continue
    match = re.search(r'xdg_surface[#@](\d+)\.get_toplevel\(new id xdg_toplevel[#@](\d+)\)', line)
    if match and match[1] in states:
        toplevels[match[2]] = states[match[1]]
        states[match[1]]['lines'].append(line)
        continue
    match = re.search(r'xdg_toplevel[#@](\d+)\.set_app_id\("([^"]+)"\)', line)
    if match and match[1] in toplevels:
        state = toplevels[match[1]]
        state['aurelia'] = match[2] == 'io.github.lucasfd3.Aurelia'
        state['lines'].append(line)
        continue
    match = re.search(r'xdg_surface[#@](\d+)\.(configure|ack_configure)\((\d+)\)', line)
    if match and match[1] in states:
        state = states[match[1]]
        if match[2] == 'configure': state['configured'].add(match[3])
        else: state['acknowledged'] = match[3] in state['configured']
        state['lines'].append(line)
        continue
    match = re.search(r'wl_surface[#@](\d+)\.(attach\(wl_buffer[#@]\d+[^)]*\)|commit\(\))', line)
    if match:
        for state in states.values():
            if state['surface'] != match[1] or not state['acknowledged']: continue
            if match[2].startswith('attach'): state['attached'] = True
            state['lines'].append(line)
            if match[2] == 'commit()' and state['attached'] and state['aurelia']:
                pathlib.Path(sys.argv[2]).write_text('\n'.join(state['lines']) + '\n')
                sys.exit(0)
sys.exit(1)
WAYLAND
}

run_session() {
  local backend=$1 binary=$2 evidence=$3 verify_instance=${4:-false}
  # EXIT runs after this function returns; keep only the trap's owned-process state in this child shell.
  app_pid='' app_start='' window_id=''
  owned_pid() {
    [ -n "$app_pid" ] && [ -r "/proc/$app_pid/stat" ] \
      && [ "$(awk '{print $22}' "/proc/$app_pid/stat")" = "$app_start" ]
  }
  owned_app() { owned_pid && [ "$(readlink -f "/proc/$app_pid/exe" 2>/dev/null)" = "$binary" ]; }
  cleanup() {
    if owned_pid; then
      kill -TERM "$app_pid" 2>/dev/null || true
      for _ in $(seq 1 100); do owned_pid || break; sleep 0.1; done
      if owned_pid; then kill -KILL "$app_pid" 2>/dev/null || true; fi
    fi
    if [ -n "$app_pid" ]; then wait "$app_pid" 2>/dev/null || true; fi
  }
  trap cleanup EXIT INT TERM
  case "${DBUS_SESSION_BUS_ADDRESS:-}" in
    '' | *"/run/user/$(id -u)/bus"*) echo "A private test bus is required." >&2; return 1 ;;
  esac
  printf 'private-session-bus=true\nservice-activation=false\n' > "$evidence/isolation.txt"
  "$binary" > "$evidence/app.log" 2>&1 &
  app_pid=$!
  app_start=$(awk '{print $22}' "/proc/$app_pid/stat")
  printf '%s\n' "$app_pid" > "$evidence/app.pid"
  for _ in $(seq 1 300); do
    if ! owned_pid; then cat "$evidence/app.log" >&2; echo "$backend app exited before showing a window." >&2; return 1; fi
    if ! owned_app; then sleep 0.1; continue; fi
    if [ "$backend" = wayland ]; then
      # DISPLAY is empty for this run, so a silent fallback to X11 cannot pass.
      if wayland_window_proof "$evidence/app.log" "$evidence/backend-proof.txt"; then
        break
      fi
    else
      # Read only window ids and PIDs until this process's own window is found.
      for candidate in $(timeout 3 xprop -root _NET_CLIENT_LIST_STACKING 2>/dev/null | rg -o '0x[0-9a-fA-F]+' || true); do
        candidate_pid=$(timeout 3 xprop -id "$candidate" _NET_WM_PID 2>/dev/null | sed -nE 's/.*= ([0-9]+)$/\1/p' || true)
        if [ "$candidate_pid" = "$app_pid" ]; then
          timeout 3 xwininfo -id "$candidate" -stats > "$evidence/window.txt"
          if rg -q 'Map State: IsViewable' "$evidence/window.txt"; then window_id=$candidate; break; fi
        fi
      done
      if [ -n "$window_id" ]; then
        timeout 3 xprop -id "$window_id" _NET_WM_PID WM_CLASS _NET_WM_NAME > "$evidence/backend-proof.txt"
        printf 'mapped-window=%s\n' "$window_id" >> "$evidence/backend-proof.txt"
        break
      fi
    fi
    sleep 0.1
  done
  [ -s "$evidence/backend-proof.txt" ] || { echo "No verified $backend window appeared within 30 seconds." >&2; return 1; }
  sleep 3
  owned_app || { cat "$evidence/app.log" >&2; echo "$backend app exited after mapping." >&2; return 1; }
  if rg -qi 'Unhandled exception|Segmentation fault|SIGSEGV|Fatal error' "$evidence/app.log"; then
    cat "$evidence/app.log" >&2; return 1
  fi
  # Capture only the owned X11 window, never the root window or the whole desktop. Wayland's
  # protocol proof is retained instead of opening an interactive screenshot permission prompt.
  if [ "$backend" = x11 ] && command -v import >/dev/null; then
    if timeout 10 import -silent -window "$window_id" "$evidence/window.png" 2> "$evidence/capture.log"; then
      printf 'own-window-capture=true\n' >> "$evidence/backend-proof.txt"
    else
      echo "Own-window capture was unavailable; mapped-window proof is retained." >> "$evidence/capture.log"
    fi
  fi
  if [ "$verify_instance" = true ]; then
    # A second background invocation must hand off and exit without opening a second window.
    timeout 15 "$binary" --background > "$evidence/second-launch.log" 2>&1
    owned_app || { echo "The first app exited during handoff." >&2; return 1; }
    printf 'background-launch-handoff=true\n' >> "$evidence/backend-proof.txt"
  fi
  printf 'PASS: %s mapped an owned native window and remained running; no input or playback.\n' "$backend" | tee "$evidence/result.txt"
}

if [ "${1:-}" = --session ]; then
  shift
  run_session "$@"
  exit
fi

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repository_root/scripts/workspace-paths.sh"
/bin/sh "$repository_root/scripts/prune-workspace.sh" || true
[ "$(uname -s)" = Linux ] || { echo "Run this check on the Linux desktop with the installed package." >&2; exit 1; }
[ "${1:-}" = --expected-version ] && { [ "$#" = 2 ] || { [ "$#" = 3 ] && [ "$3" = --verify-instance ]; }; } || { echo "Usage: $0 --expected-version 'VERSION (BUILD)'" >&2; exit 2; }
expected=$2
verify_instance=false
[ "${3:-}" != --verify-instance ] || verify_instance=true
binary=/usr/lib/aurelia-desktop/aurelia-desktop
[ -x "$binary" ] && [ -r /usr/lib/aurelia-desktop/VERSION ] || { echo "The native Aurelia package is not installed." >&2; exit 1; }
installed=$(cat /usr/lib/aurelia-desktop/VERSION)
[ "$installed" = "$expected" ] || { echo "Expected $expected, installed $installed; no app was started." >&2; exit 1; }
for tool in dbus-run-session rg xprop xwininfo timeout awk readlink sha256sum python3; do
  command -v "$tool" >/dev/null || { echo "$tool is required." >&2; exit 1; }
done

runtime=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
desktop_wayland=${WAYLAND_DISPLAY:-}
desktop_display=${DISPLAY:-}
desktop_authority=${XAUTHORITY:-}
# SSH shells often lack the compositor environment. Read just these three session variables.
while IFS='=' read -r key value; do
  case "$key" in
    WAYLAND_DISPLAY) [ -n "$desktop_wayland" ] || desktop_wayland=$value ;;
    DISPLAY) [ -n "$desktop_display" ] || desktop_display=$value ;;
    XAUTHORITY) [ -n "$desktop_authority" ] || desktop_authority=$value ;;
  esac
done < <(systemctl --user show-environment 2>/dev/null | sed -nE '/^(WAYLAND_DISPLAY|DISPLAY|XAUTHORITY)=/p')
[ -n "$desktop_wayland" ] && [ -S "$runtime/$desktop_wayland" ] || { echo "No live Wayland socket was found." >&2; exit 1; }
[ -n "$desktop_display" ] && [ -r "$desktop_authority" ] || { echo "No authorized X11 display was found." >&2; exit 1; }
umask 077
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
results="$other_root/Test Results/LinuxAppStartup-$run_id"
mkdir -p "$results"
printf 'installed=%s\nchecked-at=%s\n' "$installed" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$results/installed.txt"
sha256sum "$binary" /usr/lib/aurelia-desktop/aurelia-desktop.dll > "$results/installed.sha256"

for backend in wayland x11; do
  evidence="$results/$backend"
  synthetic_home="$evidence/home"
  mkdir -p "$synthetic_home" "$evidence/tmp"
  bus_config="$evidence/session-bus.conf"
  cat > "$bus_config" <<BUS
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:tmpdir=/tmp</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*"/>
    <allow receive_sender="*"/>
    <allow own="*"/>
  </policy>
</busconfig>
BUS
  if [ "$backend" = wayland ]; then test_wayland=$desktop_wayland; test_display=''; else test_wayland=''; test_display=$desktop_display; fi
  # Keep the shell's home intact. App paths use these explicit synthetic XDG directories;
  # the private bus has no service directories and cannot activate the owner's keyring.
  env -i PATH="$PATH" USER="$(id -un)" LOGNAME="$(id -un)" LANG=C.UTF-8 \
    XDG_CONFIG_HOME="$synthetic_home/config" XDG_DATA_HOME="$synthetic_home/data" \
    XDG_STATE_HOME="$synthetic_home/state" XDG_CACHE_HOME="$synthetic_home/cache" \
    XDG_RUNTIME_DIR="$runtime" TMPDIR="$evidence/tmp" XAUTHORITY="$desktop_authority" \
    WAYLAND_DISPLAY="$test_wayland" DISPLAY="$test_display" WAYLAND_DEBUG=client \
    AURELIA_DISPLAY_BACKEND="$backend" AURELIA_DESKTOP_SERVER="$synthetic_home/server-disabled" \
    PULSE_SERVER="unix:$evidence/no-audio" PIPEWIRE_REMOTE=aurelia-startup-no-audio \
    DOTNET_NOLOGO=1 DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    dbus-run-session --config-file "$bus_config" -- bash "$repository_root/scripts/test-linux-app-startup.sh" \
    --session "$backend" "$binary" "$evidence" "$verify_instance" 2>&1 | tee "$evidence/session.log"
done
[ "$(cat /usr/lib/aurelia-desktop/VERSION)" = "$installed" ] || { echo "The installed package changed during the check." >&2; exit 1; }
echo "Installed native startup results: $results"
