#!/bin/bash
# Installs, launches without media under Xvfb, reinstalls and removes Aurelia in disposable
# Ubuntu, Fedora and Arch containers. Only synthetic settings are created. No host home,
# server data, credentials or media are mounted. Run on Linux with rootless Podman:
#   scripts/test-linux-app-install.sh <directory containing the deb, rpm and Arch packages>
set -euo pipefail
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repository_root/scripts/workspace-paths.sh"
/bin/sh "$repository_root/scripts/prune-workspace.sh" || true
[ "$(uname -s)" = Linux ] || { echo "Run this check on Linux with Podman." >&2; exit 1; }
command -v podman >/dev/null || { echo "Podman is required." >&2; exit 1; }
packages=$(CDPATH= cd -- "${1:?Provide the Linux app package directory.}" && pwd)
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
results="$other_root/Test Results/LinuxAppInstall-$run_id"
mkdir -p "$results"

distributions="${AURELIA_TEST_DISTRIBUTIONS:-ubuntu fedora arch}"
for distribution in $distributions; do
  case "$distribution" in
    ubuntu) image="${AURELIA_TEST_UBUNTU_IMAGE:-docker.io/library/ubuntu:26.04}"; pattern='*.deb' ;;
    fedora) image="${AURELIA_TEST_FEDORA_IMAGE:-registry.fedoraproject.org/fedora:44}"; pattern='*.rpm' ;;
    arch) image="${AURELIA_TEST_ARCH_IMAGE:-docker.io/library/archlinux:base}"; pattern='*.pkg.tar.zst' ;;
    *) echo "Unknown test distribution: $distribution" >&2; exit 1 ;;
  esac
  mapfile -t candidates < <(find "$packages" -maxdepth 1 -type f -name "$pattern")
  [ "${#candidates[@]}" = 1 ] || { echo "Expected exactly one $pattern package." >&2; exit 1; }
  package=${candidates[0]##*/}
  echo "Testing $distribution with $image"
  podman pull "$image" 2>&1 | tee "$results/$distribution-pull.log"
  podman image inspect "$image" --format '{{.Id}} {{.Digest}}' > "$results/$distribution-image.txt"
  podman run --rm --interactive \
    --volume "$packages:/packages:ro" --env DISTRIBUTION="$distribution" --env PACKAGE="$package" \
    "$image" bash -s <<'CONTAINER' 2>&1 | tee "$results/$distribution.log"
set -euo pipefail
package="/packages/$PACKAGE"
case "$DISTRIBUTION" in
  ubuntu)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends python3 xvfb xauth dbus-x11 passwd util-linux "$package"
    ;;
  fedora)
    dnf install -y --setopt=install_weak_deps=False python3 xorg-x11-server-Xvfb xorg-x11-xauth dbus-daemon shadow-utils util-linux "$package"
    ;;
  arch)
    pacman -Syu --noconfirm
    pacman -S --needed --noconfirm python xorg-server-xvfb xorg-xauth dbus shadow util-linux
    pacman -U --noconfirm "$package"
    ;;
esac
test -x /usr/bin/aurelia-desktop
command -v pkexec >/dev/null
test -x /usr/lib/aurelia-desktop/server/Aurelia.Server
test -f /usr/share/applications/io.github.lucasfd3.Aurelia.desktop
test -f /usr/share/metainfo/io.github.lucasfd3.Aurelia.metainfo.xml
cat /usr/lib/aurelia-desktop/VERSION
for binary in /usr/lib/aurelia-desktop/aurelia-desktop /usr/lib/aurelia-desktop/libSkiaSharp.so; do
  missing=$(ldd "$binary" | sed -n '/not found/p')
  [ -z "$missing" ] || { printf '%s\n' "$missing" >&2; exit 1; }
done
python3 - <<'PYTHON'
import ctypes
# Resolving libVLC and its linked libraries opens no player and decodes no media.
ctypes.CDLL('libvlc.so.5')
PYTHON
useradd --create-home --home-dir /tmp/aurelia-package-user aurelia-package-test
runuser -u aurelia-package-test -- bash -s <<'LAUNCH'
set -euo pipefail
export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share"
export XDG_CACHE_HOME="$HOME/.cache" XDG_STATE_HOME="$HOME/.local/state"
mkdir -p "$XDG_CONFIG_HOME/aurelia-desktop"
printf 'Synthetic settings preservation marker\n' > "$XDG_CONFIG_HOME/aurelia-desktop/package-test-marker"
dbus-run-session -- bash -s <<'DESKTOP'
set -euo pipefail
Xvfb :91 -screen 0 1280x800x24 -nolisten tcp > "$HOME/xvfb.log" 2>&1 &
display_pid=$!
app_pid=''
trap 'test -z "$app_pid" || kill "$app_pid" 2>/dev/null || true; kill "$display_pid" 2>/dev/null || true' EXIT
export DISPLAY=:91 AURELIA_DISPLAY_BACKEND=x11
for _ in $(seq 1 50); do [ -S /tmp/.X11-unix/X91 ] && break; sleep 0.1; done
aurelia-desktop > "$HOME/app.log" 2>&1 &
app_pid=$!
sleep 8
if ! kill -0 "$app_pid" 2>/dev/null; then cat "$HOME/app.log" >&2; exit 1; fi
kill -TERM "$app_pid"
wait "$app_pid" || [ "$?" -eq 143 ]
app_pid=''
cat "$HOME/app.log"
DESKTOP
python3 - <<'SERVER'
import json, os, pathlib, ssl, subprocess, time, urllib.request

server = pathlib.Path('/usr/lib/aurelia-desktop/server/Aurelia.Server')
dependencies = json.loads((server.parent / (server.name + '.deps.json')).read_text())
expected = next(name.split('/', 1)[1] for name in dependencies['libraries'] if name.startswith('Aurelia.Server/'))
data = pathlib.Path.home() / 'synthetic-hosted-server'
data.mkdir(mode=0o700)
environment = os.environ.copy()
environment.update(AURELIA_BOOTSTRAP_TOKEN='synthetic-package-startup-bootstrap-token-only',
                   AURELIA_LAN_ENABLED='false', Aurelia__Ffmpeg='off')
log = pathlib.Path.home() / 'server.log'
with log.open('w') as output:
    process = subprocess.Popen([str(server), 'run', '--data-dir', str(data), '--urls',
                                'http://127.0.0.1:43110', '--local-https', '--lan-port', '43111'],
                               cwd=data, env=environment, stdout=output, stderr=subprocess.STDOUT)
    try:
        deadline = time.monotonic() + 45
        while True:
            if process.poll() is not None:
                raise AssertionError('The packaged server exited during startup')
            try:
                with urllib.request.urlopen('http://127.0.0.1:43110/api/v1/server/info', timeout=1) as response:
                    info = json.load(response)
                break
            except (OSError, ValueError):
                if time.monotonic() >= deadline:
                    raise AssertionError('The packaged server did not become ready')
                time.sleep(0.2)
        assert info['version'] == expected, info
        assert info['isSetup'] is False and info['lanAccessEnabled'] is False, info
        with urllib.request.urlopen('http://127.0.0.1:43110/api/v1/health', timeout=3) as response:
            assert json.load(response)['status'] == 'ok'
        context = ssl._create_unverified_context()  # This synthetic server creates its own test certificate.
        with urllib.request.urlopen('https://127.0.0.1:43111/api/v1/server/info', context=context, timeout=3) as response:
            assert json.load(response)['version'] == expected
        print('PASS: packaged self-contained server ' + expected + ', empty setup, healthy database, local TLS; no media opened.')
    except BaseException:
        output.flush()
        print(log.read_text())
        raise
    finally:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
            raise AssertionError('The packaged server did not stop after SIGTERM')
SERVER
LAUNCH
case "$DISTRIBUTION" in
  ubuntu) apt-get install -y --reinstall --no-install-recommends "$package" ;;
  fedora) dnf reinstall -y --setopt=install_weak_deps=False "$package" ;;
  arch) pacman -U --noconfirm "$package" ;;
esac
test "$(cat /tmp/aurelia-package-user/.config/aurelia-desktop/package-test-marker)" = 'Synthetic settings preservation marker'
case "$DISTRIBUTION" in
  ubuntu) apt-get remove -y aurelia-desktop ;;
  fedora) dnf remove -y aurelia-desktop ;;
  arch) pacman -R --noconfirm aurelia-desktop ;;
esac
test ! -e /usr/bin/aurelia-desktop
test -f /tmp/aurelia-package-user/.config/aurelia-desktop/package-test-marker
echo "PASS: dependencies, headless launch, reinstall preserves settings, uninstall preserves settings."
CONTAINER
done
echo "Linux package installation results: $results"
