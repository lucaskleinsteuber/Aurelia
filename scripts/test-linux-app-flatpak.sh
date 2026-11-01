#!/bin/bash
# Installs the actual bundle in a disposable user installation, checks its bundled server and
# runtime tools, and starts its real UI on private headless X11 and Wayland compositors.
# No account, library, personal keyring or media is used. No synthetic HOME is assigned: an
# outer mount namespace hides real home contents, including ~/.var/app. A private network
# namespace keeps loopback ports and X11's abstract sockets separate from the real desktop.
# Usage: test-linux-app-flatpak.sh <bundle.flatpak> '1.0.0 (5)'
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

isolated_check() {
  local work=$1 expected=$2
  export FLATPAK_USER_DIR="$work/installation" FLATPAK_GL_DRIVERS=default
  export XDG_CONFIG_HOME="$work/config" XDG_DATA_HOME="$work/data"
  export XDG_CACHE_HOME="$work/cache" XDG_STATE_HOME="$work/state"
  export XDG_RUNTIME_DIR="/run/user/$(id -u)"
  mkdir -p "$XDG_RUNTIME_DIR" "$work/evidence" "$work/installation"
  chmod 700 "$XDG_RUNTIME_DIR"
  local app_id=io.github.lucasfd3.Aurelia
  # All process/instance ids belong to this private runtime directory and PID namespace.
  app_job='' compositor_job='' app_instance=''
  stop_job() {
    local job=$1
    [ -n "$job" ] || return 0
    kill -TERM "$job" 2>/dev/null || true
    for _ in $(seq 1 50); do kill -0 "$job" 2>/dev/null || break; sleep .1; done
    kill -KILL "$job" 2>/dev/null || true
    wait "$job" 2>/dev/null || true
  }
  stop_app() {
    if [ -n "$app_instance" ]; then flatpak kill "$app_instance" 2>/dev/null || true; fi
    stop_job "$app_job"
    app_job='' app_instance=''
  }
  stop_compositor() {
    stop_job "$compositor_job"
    compositor_job=''
  }
  finish_isolated() { stop_app; stop_compositor; }
  trap finish_isolated EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  local cache_repo="$work/runtime-repo"
  ostree --repo="$cache_repo" init --mode=archive
  while IFS=$'\t' read -r ref commit; do
    ostree --repo="$cache_repo" pull-local --untrusted --disable-fsync /run/aurelia-runtime-source "$commit"
    ostree --repo="$cache_repo" refs --create="$ref" "$commit"
  done < "$work/runtime-source.tsv"
  flatpak build-update-repo "$cache_repo"
  flatpak remote-add --user --no-gpg-verify cached-runtimes "file://$cache_repo"
  while IFS=$'\t' read -r ref commit; do
    flatpak install --user --assumeyes --noninteractive --no-deps --no-related cached-runtimes "$ref"
    [ "$(flatpak info --user --show-commit "$ref")" = "$commit" ]
  done < "$work/runtime-source.tsv"
  flatpak install --user --assumeyes --noninteractive --no-deps --no-related --bundle /run/aurelia-candidate.flatpak
  flatpak info --user "$app_id" > "$work/evidence/installed.txt"
  flatpak info --user --show-metadata "$app_id" > "$work/evidence/metadata.txt"
  local common=(run --user --no-documents-portal --no-a11y-bus)
  flatpak "${common[@]}" --command=sh "$app_id" -c 'cat /app/lib/aurelia-desktop/VERSION' > "$work/evidence/version.txt"
  [ "$(cat "$work/evidence/version.txt")" = "$expected" ] || { echo "The installed bundle has the wrong version." >&2; return 1; }
  flatpak "${common[@]}" --command=sh "$app_id" -c '
    set -eu
    export LD_LIBRARY_PATH="/app/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    ldd /app/lib/libvlc.so.5
    ldd /app/lib/vlc/plugins/codec/libavcodec_plugin.so
    test -x /app/lib/aurelia-desktop/server/Aurelia.Server
    test -f /app/lib/vlc/plugins/audio_output/libpulse_plugin.so
  ' > "$work/evidence/libraries.txt" 2>&1
  if rg -q 'not found' "$work/evidence/libraries.txt"; then
    echo "A bundled decoder dependency could not be resolved." >&2; return 1
  fi
  # Match HostedServerEnvironment: the installed app linker cache also prefers /app/lib, so
  # runtime codec directories must lead the environment after filtering private decoder paths.
  flatpak "${common[@]}" --command=sh "$app_id" -c '
    set -eu
    export LD_LIBRARY_PATH="/app/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" VLC_PLUGIN_PATH=/app/lib/vlc/plugins
    filtered=$(printf "%s" "${LD_LIBRARY_PATH:-}" | tr ":" "\n" | awk '\''$0 != "/app/lib" && $0 != "/app/lib64" && index($0,"/app/lib/") != 1 && index($0,"/app/lib64/") != 1 && length($0) { p=p (length(p)?":":"") $0 } END { print p }'\'')
    export LD_LIBRARY_PATH="/usr/lib/x86_64-linux-gnu/codecs-extra/lib:/usr/lib/x86_64-linux-gnu${filtered:+:$filtered}"
    unset VLC_PLUGIN_PATH
    ldd /usr/bin/ffmpeg /usr/bin/ffprobe
    /usr/bin/ffprobe -version
    /usr/bin/ffmpeg -hide_banner -encoders
  ' > "$work/evidence/runtime-ffmpeg-encoders.txt" 2>&1
  if rg -q 'not found|lib(av(codec|format|util|filter|device)|sw(scale|resample))\.so[^ ]* => /app/' "$work/evidence/runtime-ffmpeg-encoders.txt"; then
    echo "The runtime tools resolved an incompatible decoder dependency." >&2; return 1
  fi
  rg -q '^[[:space:]]*A[^ ]*[[:space:]]+aac[[:space:]]' "$work/evidence/runtime-ffmpeg-encoders.txt"
  rg -q '^[[:space:]]*V[^ ]*[[:space:]]+libx264[[:space:]]' "$work/evidence/runtime-ffmpeg-encoders.txt"
  rg -q '^[[:space:]]*A[^ ]*[[:space:]]+libopus[[:space:]]' "$work/evidence/runtime-ffmpeg-encoders.txt"

  # Start only the packaged server, with no owner and no media, on two free loopback ports.
  python3 - "$work/evidence" "$app_id" <<'PYTHON'
import json, os, pathlib, secrets, signal, socket, ssl, subprocess, sys, time, urllib.request
out, app_id = pathlib.Path(sys.argv[1]), sys.argv[2]
dependencies = json.loads(subprocess.check_output([
    'flatpak', 'run', '--user', '--no-documents-portal', '--no-a11y-bus', '--die-with-parent',
    '--command=cat', app_id, '/app/lib/aurelia-desktop/server/Aurelia.Server.deps.json']))
expected = next(name.split('/', 1)[1] for name in dependencies['libraries'] if name.startswith('Aurelia.Server/'))
def port():
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        return listener.getsockname()[1]
http, https = port(), port()
while https == http: https = port()
filtered = r'''set -eu
export LD_LIBRARY_PATH="/app/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" VLC_PLUGIN_PATH=/app/lib/vlc/plugins
filtered=$(printf "%s" "${LD_LIBRARY_PATH:-}" | tr ":" "\n" | awk '$0 != "/app/lib" && $0 != "/app/lib64" && index($0,"/app/lib/") != 1 && index($0,"/app/lib64/") != 1 && length($0) { p=p (length(p)?":":"") $0 } END { print p }')
export LD_LIBRARY_PATH="/usr/lib/x86_64-linux-gnu/codecs-extra/lib:/usr/lib/x86_64-linux-gnu${filtered:+:$filtered}"
unset VLC_PLUGIN_PATH
exec /app/lib/aurelia-desktop/server/Aurelia.Server "$@"'''
command = ['flatpak', 'run', '--user', '--no-documents-portal', '--no-a11y-bus', '--die-with-parent',
           '--env=AURELIA_BOOTSTRAP_TOKEN=' + secrets.token_hex(32), '--env=AURELIA_LAN_ENABLED=false',
           '--env=Aurelia__Ffmpeg=off', '--command=sh', app_id, '-c', filtered, 'aurelia-server-probe',
           'run', '--data-dir', '/tmp/aurelia-synthetic-server', '--urls', f'http://127.0.0.1:{http}',
           '--local-https', '--lan-port', str(https)]
log = (out / 'server.log').open('w')
process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
try:
    deadline = time.monotonic() + 45
    while True:
        if process.poll() is not None: raise RuntimeError('Packaged Flatpak server exited before readiness')
        try:
            with urllib.request.urlopen(f'http://127.0.0.1:{http}/api/v1/server/info', timeout=1) as response: info = json.load(response)
            break
        except (OSError, ValueError):
            if time.monotonic() >= deadline: raise RuntimeError('Packaged Flatpak server readiness timed out')
            time.sleep(.2)
    assert info['version'] == expected, info
    assert info['isSetup'] is False and info['lanAccessEnabled'] is False, info
    with urllib.request.urlopen(f'http://127.0.0.1:{http}/api/v1/health/live', timeout=3) as response: assert response.status == 200
    with urllib.request.urlopen(f'http://127.0.0.1:{http}/api/v1/health', timeout=3) as response: assert json.load(response)['status'] == 'ok'
    with urllib.request.urlopen(f'https://127.0.0.1:{https}/api/v1/server/info', context=ssl._create_unverified_context(), timeout=3) as response: secure = json.load(response)
    assert secure['serverId'] == info['serverId'] and secure['version'] == info['version']
    (out / 'server-info.json').write_text(json.dumps(info, indent=2) + '\n')
    print('PASS: packaged Flatpak server ' + expected + ', healthy empty database and loopback HTTPS, without accounts or media.')
finally:
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try: process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL); process.wait(timeout=5)
            raise RuntimeError('Packaged Flatpak server did not stop after SIGTERM')
    log.close()
PYTHON

  for backend in x11 wayland; do
    local evidence="$work/evidence/$backend"
    mkdir -p "$evidence"
    if [ "$backend" = x11 ]; then
      mkdir -p /tmp/.X11-unix
      chmod 1777 /tmp/.X11-unix
      LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe \
        Xvfb -displayfd 3 -screen 0 1280x800x24 -extension GLX -nolisten tcp -ac > "$evidence/compositor.log" 2>&1 3> "$evidence/display" &
      compositor_job=$!
      for _ in $(seq 1 100); do [ -s "$evidence/display" ] && break; sleep .1; done
      [ -s "$evidence/display" ] || { cat "$evidence/compositor.log" >&2; return 1; }
      export DISPLAY=":$(cat "$evidence/display")"
      unset WAYLAND_DISPLAY
    else
      weston --no-config --backend=headless --renderer=pixman --socket=wayland-aurelia-test --idle-time=0 \
        --width=1280 --height=800 > "$evidence/compositor.log" 2>&1 &
      compositor_job=$!
      export WAYLAND_DISPLAY=wayland-aurelia-test
      unset DISPLAY
      for _ in $(seq 1 100); do [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ] && break; sleep .1; done
      [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ] || { cat "$evidence/compositor.log" >&2; return 1; }
    fi
    local display_options=(--socket="$backend")
    if [ "$backend" = x11 ]; then display_options+=(--nosocket=wayland); else display_options+=(--nosocket=x11); fi
    flatpak "${common[@]}" --die-with-parent --instance-id-fd=3 "${display_options[@]}" \
      --env=AURELIA_DISPLAY_BACKEND="$backend" --env=WAYLAND_DEBUG=client \
      --env=LIBGL_ALWAYS_SOFTWARE=1 --env=GALLIUM_DRIVER=llvmpipe \
      --env=AURELIA_DESKTOP_SERVER=/tmp/disabled-server \
      "$app_id" > "$evidence/app.log" 2>&1 3> "$evidence/instance" &
    app_job=$!
    local ready=false
    for _ in $(seq 1 300); do
      kill -0 "$app_job" 2>/dev/null || { cat "$evidence/app.log" >&2; return 1; }
      if [ "$backend" = x11 ]; then
        xwininfo -root -tree > "$evidence/window-tree.txt"
        window_id=$(sed -nE '/"Aurelia"/s/^[[:space:]]*(0x[0-9a-fA-F]+).*/\1/p' "$evidence/window-tree.txt" | head -1)
        if [ -n "$window_id" ]; then
          xwininfo -id "$window_id" -stats > "$evidence/backend-proof.txt"
          if rg -q 'Map State: IsViewable' "$evidence/backend-proof.txt"; then ready=true; break; fi
        fi
      elif wayland_window_proof "$evidence/app.log" "$evidence/backend-proof.txt"; then
        ready=true
        break
      fi
      sleep .1
    done
    [ "$ready" = true ] || { cat "$evidence/app.log" >&2; return 1; }
    app_instance=$(cat "$evidence/instance")
    [ -n "$app_instance" ] || return 1
    sleep 3
    kill -0 "$app_job"
    if rg -qi 'Unhandled exception|Segmentation fault|SIGSEGV|Fatal error' "$evidence/app.log"; then cat "$evidence/app.log" >&2; return 1; fi
    printf 'PASS: real installed Flatpak mapped a private headless %s window.\n' "$backend" | tee "$evidence/result.txt"
    stop_app
    stop_compositor
  done
  flatpak uninstall --user --assumeyes --noninteractive --delete-data "$app_id"
  [ -z "$(flatpak list --user --app --columns=application)" ]
  printf 'PASS: bundle install, library resolution, runtime encoders, packaged server, X11, Wayland, and uninstall.\n' > "$work/evidence/result.txt"
}

if [ "${1:-}" = --isolated ]; then shift; isolated_check "$@"; exit; fi
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repository_root/scripts/workspace-paths.sh"
/bin/sh "$repository_root/scripts/prune-workspace.sh" || true
[ "$(uname -s)" = Linux ] || { echo "Run this package check on Linux." >&2; exit 1; }
[ "$#" = 2 ] || { echo "Usage: $0 <bundle.flatpak> 'VERSION (BUILD)'" >&2; exit 2; }
bundle=$(realpath "$1") expected=$2
[ -f "$bundle" ] || { echo "The bundle does not exist." >&2; exit 1; }
for tool in flatpak ostree bwrap dbus-run-session Xvfb weston xwininfo python3 rg; do command -v "$tool" >/dev/null || { echo "$tool is required." >&2; exit 1; }; done
source_repo="${FLATPAK_USER_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/flatpak}/repo"
[ -d "$source_repo" ] || { echo "No existing runtime source repository was found." >&2; exit 1; }
umask 077
results="$other_root/Test Results/LinuxAppFlatpak-$(date -u +%Y%m%dT%H%M%SZ)-$$"
work="$results/private-work"
mkdir -p "$work/evidence"
baseline_ready=false
finish_outer() {
  local status=$?
  if [ -d "$work/evidence" ] && ! cp -a "$work/evidence" "$results/evidence"; then status=1; fi
  if [ "$baseline_ready" = true ]; then
    if ! flatpak list --user --app --columns=ref,active > "$results/default-user-apps-after.txt"; then status=1; fi
    if ! cmp -s "$results/default-user-apps-before.txt" "$results/default-user-apps-after.txt"; then
      echo "The default user installation changed during this check." >&2
      status=1
    fi
  fi
  if ! rm -rf -- "$work"; then status=1; fi
  echo "Flatpak bundle results: $results"
  exit "$status"
}
trap finish_outer EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cp "$repository_root/scripts/test-linux-app-flatpak.sh" "$work/checker.sh"
sha256sum "$bundle" > "$results/bundle.sha256"
flatpak list --user --app --columns=ref,active > "$results/default-user-apps-before.txt"
baseline_ready=true
for ref in org.freedesktop.Platform/x86_64/26.08 org.freedesktop.Platform.GL.default/x86_64/26.08 \
  org.freedesktop.Platform.GL.default/x86_64/26.08-extra org.freedesktop.Platform.codecs-extra/x86_64/26.08-extra; do
  commit=$(flatpak info --user --show-commit "$ref")
  printf 'runtime/%s\t%s\n' "$ref" "$commit" >> "$work/runtime-source.tsv"
done
cp "$work/runtime-source.tsv" "$results/runtime-source.tsv"
cat > "$work/bus.conf" <<'BUS'
<busconfig><type>session</type><listen>unix:tmpdir=/tmp</listen><auth>EXTERNAL</auth>
<policy context="default"><allow send_destination="*"/><allow receive_sender="*"/><allow own="*"/></policy>
</busconfig>
BUS
# Hide the real home directory selected by passwd, without substituting another HOME. The user repository is only
# available through the explicit read-only runtime source mount; its objects are checksum-verified.
bwrap --die-with-parent --unshare-pid --unshare-ipc --unshare-net --unshare-uts --hostname aurelia-flatpak-test \
  --ro-bind / / --dev /dev --proc /proc \
  --tmpfs /tmp --tmpfs /var/tmp --tmpfs /run --tmpfs "$HOME" --bind "$work" "$work" \
  --ro-bind "$source_repo" /run/aurelia-runtime-source --ro-bind "$bundle" /run/aurelia-candidate.flatpak \
  --clearenv --setenv PATH /usr/bin:/bin --setenv USER "$(id -un)" --setenv LOGNAME "$(id -un)" \
  --setenv LANG C.UTF-8 --setenv XDG_RUNTIME_DIR "/run/user/$(id -u)" --chdir "$work" \
  dbus-run-session --config-file "$work/bus.conf" -- bash "$work/checker.sh" --isolated "$work" "$expected" \
  2>&1 | tee "$results/run.log"
