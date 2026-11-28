#!/bin/bash
# Installs or updates Tarven Server on a Linux computer with systemd, from the unpacked
# download: sudo ./install.sh. An update replaces only the program; the server's data in
# /var/lib/tarven, its accounts and settings stay. --uninstall removes the program and keeps
# the data unless --remove-data is added. Media folders are never touched. `sudo tarven update`
# downloads a newer package and runs its installer the same way.
set -euo pipefail

package_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
install_root=/opt/tarven
data_dir=/var/lib/tarven
unit=/etc/systemd/system/tarven.service
command_path=/usr/local/bin/tarven
lan_port=43111

if [ "$(id -u)" -ne 0 ]; then
  echo "Run the installer with sudo: sudo $0 $*" >&2
  exit 1
fi
if ! command -v systemctl >/dev/null 2>&1; then
  echo "Tarven Server needs a Linux system with systemd." >&2
  exit 1
fi

firewall() {
  # Only an active ufw is changed; other firewalls are left to the administrator.
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "$lan_port/tcp" comment 'Tarven Server' >/dev/null
    ufw allow 5353/udp comment 'Tarven Server discovery' >/dev/null
  fi
}

# Tarven was called Aurelia until server 3.0.0. An installation from that time is taken over once:
# its service user keeps its number and is renamed, the data and settings folders are renamed in
# place (nothing is copied), the old services are removed, and this installer then continues as an
# update. The old update command may be running this installer from aurelia-update-request.service,
# so that service and aurelia-update-check.service are only disabled, never stopped.
legacy_root=/opt/aurelia
legacy_data=/var/lib/aurelia
legacy_units="aurelia.service aurelia-start.socket aurelia-start.service aurelia-autosleep.service
  aurelia-autosleep.timer aurelia-wake-on-lan.service aurelia-update-request.path aurelia-update-request.service
  aurelia-update-check.timer aurelia-update-check.service aurelia-power-request.path aurelia-power-request.service"
migrate_from_aurelia() {
  [ -d "$legacy_root" ] || [ -d "$legacy_data" ] || return 0
  if [ -e "$install_root" ] || [ -e "$data_dir" ]; then
    echo "Both $legacy_root or $legacy_data and $install_root or $data_dir exist; the Aurelia installation is left as it is." >&2
    return 0
  fi
  echo "Taking over the Aurelia Server installation as Tarven Server..."
  systemctl stop aurelia-start.socket aurelia aurelia-autosleep.timer aurelia-update-request.path \
    aurelia-update-check.timer aurelia-power-request.path aurelia-start.service 2>/dev/null || true
  # shellcheck disable=SC2086
  systemctl disable $legacy_units >/dev/null 2>&1 || true
  if id aurelia >/dev/null 2>&1 && ! id tarven >/dev/null 2>&1; then
    usermod -l tarven aurelia
    getent group aurelia >/dev/null 2>&1 && groupmod -n tarven aurelia
    usermod -d "$data_dir" tarven
  fi
  [ -d "$legacy_data" ] && mv "$legacy_data" "$data_dir"
  if [ -d /etc/aurelia ] && [ ! -e /etc/tarven ]; then mv /etc/aurelia /etc/tarven; fi
  if [ -f /etc/aurelia-autosleep.conf ] && [ ! -e /etc/tarven-autosleep.conf ]; then
    mv /etc/aurelia-autosleep.conf /etc/tarven-autosleep.conf
  fi
  [ -d "$legacy_root" ] && mv "$legacy_root" "$install_root"
  # The old program keeps its name in server.old until the new one is ready, so a rollback still finds it.
  rm -f /usr/local/bin/aurelia
  for legacy_unit in $legacy_units; do rm -f "/etc/systemd/system/$legacy_unit"; done
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw delete allow "$lan_port/tcp" >/dev/null 2>&1 || true
    ufw delete allow 5353/udp >/dev/null 2>&1 || true
  fi
  systemctl daemon-reload
}

if [ "${1:-}" = --uninstall ]; then
  remove_data=false
  [ "${2:-}" = --remove-data ] && remove_data=true
  systemctl disable --now tarven tarven-autosleep.timer tarven-start.socket tarven-update-request.path \
    tarven-update-check.timer tarven-power-request.path 2>/dev/null || true
  systemctl stop tarven-autosleep.service tarven-update-request.service tarven-update-check.service \
    tarven-power-request.service tarven-start.service 2>/dev/null || true
  systemctl disable tarven-wake-on-lan.service 2>/dev/null || true
  rm -f "$unit" "$command_path" /usr/local/bin/aurelia /etc/tarven-autosleep.conf /etc/systemd/system/tarven-autosleep.service \
    /etc/systemd/system/tarven-autosleep.timer /etc/systemd/system/tarven-wake-on-lan.service \
    /etc/systemd/system/tarven-start.socket /etc/systemd/system/tarven-start.service \
    /etc/systemd/system/tarven-update-request.path /etc/systemd/system/tarven-update-request.service \
    /etc/systemd/system/tarven-update-check.timer /etc/systemd/system/tarven-update-check.service \
    /etc/systemd/system/tarven-power-request.path /etc/systemd/system/tarven-power-request.service \
    /etc/tarven/github-token /etc/tarven/update-channel /etc/tarven/test-update-source
  rmdir /etc/tarven 2>/dev/null || true
  systemctl daemon-reload
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw delete allow "$lan_port/tcp" >/dev/null 2>&1 || true
    ufw delete allow 5353/udp >/dev/null 2>&1 || true
  fi
  rm -rf "$install_root"
  if $remove_data; then
    read -r -p "Delete the server data in $data_dir (accounts, library, progress)? [y/N] " answer
    case "$answer" in
      y|Y|yes|YES) rm -rf "$data_dir"; userdel tarven 2>/dev/null || true; echo "Server data deleted." ;;
      *) echo "Server data kept in $data_dir." ;;
    esac
  else
    echo "Tarven Server was removed. Its data stays in $data_dir."
  fi
  exit 0
fi

package_arch=$(cat "$package_root/ARCHITECTURE")
case "$(uname -m)" in
  x86_64|amd64) machine_arch=x64 ;;
  aarch64|arm64) machine_arch=arm64 ;;
  *) machine_arch=$(uname -m) ;;
esac
if [ "$package_arch" != "$machine_arch" ]; then
  echo "This package is for $package_arch, but this computer is $machine_arch. Download the $machine_arch package." >&2
  exit 1
fi

# .NET sorts and compares titles with ICU, which minimal installations may leave out.
if ! ldconfig -p 2>/dev/null | grep -F 'libicuuc.so' >/dev/null; then
  icu=""
  command -v apt-cache >/dev/null 2>&1 \
    && icu=$(apt-cache search --names-only '^libicu[0-9]+$' | awk '{print $1}' | sort -V | tail -n 1)
  if [ -z "$icu" ]; then
    echo "Tarven Server needs the ICU library (libicu). Install it with your package manager first." >&2
    exit 1
  fi
  echo "Installing $icu, which Tarven Server needs..."
  apt-get install -y "$icu" >/dev/null
fi

# Subtitles from speech use the distribution's whisper.cpp when it has one (Debian, Ubuntu). It
# is optional; the model is downloaded later, only when the owner asks for it in Settings.
if [ ! -x /usr/bin/whisper-cli ] && command -v apt-get >/dev/null 2>&1; then
  apt-get install -y whisper.cpp >/dev/null 2>&1 \
    || echo "whisper.cpp isn't available here; subtitles from speech stay off until it is installed." >&2
fi

# Web browsers play MKV and other files through live conversion with the system's ffmpeg. The
# server works without it; browsers then play only files they open themselves.
if [ ! -x /usr/bin/ffmpeg ] || [ ! -x /usr/bin/ffprobe ]; then
  if command -v apt-get >/dev/null 2>&1; then
    echo "Installing ffmpeg, which lets web browsers play MKV and other files..."
    apt-get install -y ffmpeg >/dev/null 2>&1 \
      || { apt-get update -qq >/dev/null 2>&1 && apt-get install -y ffmpeg >/dev/null 2>&1; } \
      || echo "ffmpeg could not be installed. Web browsers play only MP4 files until it is: sudo apt install ffmpeg" >&2
  else
    echo "Install ffmpeg with your package manager so web browsers can play MKV and other files." >&2
  fi
fi

# Wake-on-LAN needs ethtool so sleep and shut-down power saving can wake the computer again.
if ! command -v ethtool >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    echo "Installing ethtool, which enables Wake-on-LAN for power saving..."
    apt-get install -y ethtool >/dev/null 2>&1 \
      || { apt-get update -qq >/dev/null 2>&1 && apt-get install -y ethtool >/dev/null 2>&1; } \
      || echo "ethtool could not be installed. Sleep and shut-down power saving stay unavailable until it is: sudo apt install ethtool" >&2
  else
    echo "Install ethtool with your package manager so Wake-on-LAN power saving can work." >&2
  fi
fi

migrate_from_aurelia

if ! id tarven >/dev/null 2>&1; then
  useradd --system --user-group --home-dir "$data_dir" --no-create-home --shell /usr/sbin/nologin tarven
fi
install -d -o tarven -g tarven -m 0700 "$data_dir"

# A video chip converts titles much faster than the processor. The server's user needs the render
# and video groups to open it, and VA-API needs the driver for this computer's graphics.
for group in render video; do
  if getent group "$group" >/dev/null 2>&1 && ! id -nG tarven | tr ' ' '\n' | grep -qx "$group"; then
    usermod -aG "$group" tarven || true
  fi
done
if command -v apt-get >/dev/null 2>&1 && [ -d /sys/class/drm ]; then
  vendors=$(cat /sys/class/drm/card*/device/vendor 2>/dev/null | sort -u || true)
  drivers=""
  # Intel from 2015 on uses intel-media-va-driver, older Intel i965-va-driver; libva picks the one that works.
  case "$vendors" in *0x8086*) drivers="intel-media-va-driver i965-va-driver" ;; esac
  case "$vendors" in *0x1002*) drivers="$drivers mesa-va-drivers" ;; esac
  for driver in $drivers; do
    dpkg -s "$driver" >/dev/null 2>&1 && continue
    echo "Installing $driver, which lets the server convert titles on the video chip..."
    apt-get install -y "$driver" >/dev/null 2>&1 \
      || { apt-get update -qq >/dev/null 2>&1 && apt-get install -y "$driver" >/dev/null 2>&1; } \
      || echo "$driver could not be installed. Titles convert on the processor until a video chip driver is: sudo apt install $driver" >&2
  done
fi

updating=false
[ -d "$install_root/server" ] && updating=true
if command -v flock >/dev/null 2>&1; then
  exec 8>/run/tarven-install.lock
  flock 8
fi
# A device connecting meanwhile must not start the program while it is replaced.
systemctl stop tarven-start.socket tarven 2>/dev/null || true

# The new program is copied next to the old one first, so a failed copy leaves the old one whole.
# Keep server.old until the new version answers its readiness check; roll back if it fails to start.
install -d -m 0755 "$install_root"
rm -rf "$install_root/server.new"
cp -R "$package_root/server" "$install_root/server.new"
chown -R root:root "$install_root/server.new"
chmod -R u=rwX,go=rX "$install_root/server.new"
chmod 0755 "$install_root/server.new/Tarven.Server"
rm -rf "$install_root/server.old" "$install_root/VERSION.old"
[ -d "$install_root/server" ] && mv "$install_root/server" "$install_root/server.old"
[ -f "$install_root/VERSION" ] && cp -p "$install_root/VERSION" "$install_root/VERSION.old"
mv "$install_root/server.new" "$install_root/server"

rm -rf "$install_root/notices"
cp -R "$package_root/notices" "$install_root/notices"
install -m 0644 "$package_root/VERSION" "$install_root/VERSION"
# The GitHub repository that `tarven update` downloads from, when the package was built from one.
[ -f "$package_root/REPOSITORY" ] && install -m 0644 "$package_root/REPOSITORY" "$install_root/REPOSITORY"
install -m 0755 "$package_root/install.sh" "$install_root/install.sh"
install -m 0755 "$package_root/tarven" "$command_path"
# `aurelia`, the command's name before the rename to Tarven, keeps working.
ln -sfn "$command_path" /usr/local/bin/aurelia
install -m 0644 "$package_root/tarven.service" "$unit"
# Wake-on-LAN is always allowed. Power saving stays as it was; it is turned on in the app's server
# settings or with `sudo tarven sleep`.
install -m 0755 "$package_root/tarven-autosleep" "$install_root/tarven-autosleep"
install -m 0644 "$package_root/tarven-sleep-settings" "$install_root/tarven-sleep-settings"
install -m 0755 "$package_root/tarven-wake-on-lan" "$install_root/tarven-wake-on-lan"
for sleep_unit in tarven-autosleep.service tarven-autosleep.timer tarven-wake-on-lan.service \
  tarven-start.socket tarven-start.service tarven-update-request.path tarven-update-request.service \
  tarven-update-check.timer tarven-update-check.service tarven-power-request.path \
  tarven-power-request.service; do
  install -m 0644 "$package_root/$sleep_unit" "/etc/systemd/system/$sleep_unit"
done
chown -R root:root "$install_root/notices" "$install_root/VERSION" "$install_root/install.sh"

# Sleep settings used to be in /etc (1.8.2-1.8.3), with the timer's state as on/off. They move
# to the data folder, where the app can change them; the timer then runs always.
settings="$data_dir/sleep-settings"
if [ ! -e "$settings" ]; then
  . "$install_root/tarven-sleep-settings"
  read_sleep_settings /etc/tarven-autosleep.conf
  MODE=off
  systemctl is-enabled --quiet tarven-autosleep.timer 2>/dev/null && MODE=sleep
  write_sleep_settings "$settings"
fi
rm -f /etc/tarven-autosleep.conf

systemctl daemon-reload
systemctl enable tarven >/dev/null
systemctl start tarven

wait_until_ready() {
  for _ in $(seq 1 60); do
    if "$install_root/server/Tarven.Server" server identity >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  return 1
}

if ! wait_until_ready; then
  echo "Tarven Server did not become ready after installation." >&2
  if $updating && [ -d "$install_root/server.old" ]; then
    echo "Restoring the previous Tarven Server version..." >&2
    systemctl stop tarven 2>/dev/null || true
    rm -rf "$install_root/server.failed"
    mv "$install_root/server" "$install_root/server.failed" 2>/dev/null || true
    mv "$install_root/server.old" "$install_root/server"
    [ -f "$install_root/VERSION.old" ] && mv "$install_root/VERSION.old" "$install_root/VERSION"
    # A version from before the rename (Aurelia) runs under the new service name, with its
    # database under the old name again.
    if [ ! -e "$install_root/server/Tarven.Server" ] && [ -x "$install_root/server/Aurelia.Server" ]; then
      ln -s Aurelia.Server "$install_root/server/Tarven.Server"
      if [ -f "$data_dir/tarven.db" ] && [ ! -e "$data_dir/aurelia.db" ]; then
        for suffix in "" -wal -shm -journal; do
          [ -e "$data_dir/tarven.db$suffix" ] && mv "$data_dir/tarven.db$suffix" "$data_dir/aurelia.db$suffix"
        done
      fi
    fi
    rm -rf "$install_root/server.failed"
    systemctl start tarven || true
  fi
  exit 1
fi
rm -rf "$install_root/server.old" "$install_root/VERSION.old"
systemctl enable --now tarven-wake-on-lan.service >/dev/null 2>&1 || true
systemctl enable --now tarven-autosleep.timer >/dev/null
# Tarven on a Mac can ask for an update check or an update; the server looks once a day by itself.
systemctl enable --now tarven-update-request.path tarven-update-check.timer >/dev/null 2>&1
# An app, Home Assistant or Siri can ask to sleep, turn off or stop now.
systemctl enable --now tarven-power-request.path >/dev/null 2>&1
firewall

echo "Tarven Server $(cat "$install_root/VERSION") is installed and runs as a service."
if $updating; then
  echo "It was updated; accounts, library and settings are unchanged."
else
  echo "Set it up next with: sudo tarven setup (in a web browser, or here in the terminal)"
fi
