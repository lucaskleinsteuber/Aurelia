#!/bin/bash
# Installs or updates Aurelia Server on a Linux computer with systemd, from the unpacked
# download: sudo ./install.sh. An update replaces only the program; the server's data in
# /var/lib/aurelia, its accounts and settings stay. --uninstall removes the program and keeps
# the data unless --remove-data is added. Media folders are never touched. `sudo aurelia update`
# downloads a newer package and runs its installer the same way.
set -euo pipefail

package_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
install_root=/opt/aurelia
data_dir=/var/lib/aurelia
unit=/etc/systemd/system/aurelia.service
command_path=/usr/local/bin/aurelia
lan_port=43111

if [ "$(id -u)" -ne 0 ]; then
  echo "Run the installer with sudo: sudo $0 $*" >&2
  exit 1
fi
if ! command -v systemctl >/dev/null 2>&1; then
  echo "Aurelia Server needs a Linux system with systemd." >&2
  exit 1
fi

firewall() {
  # Only an active ufw is changed; other firewalls are left to the administrator.
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "$lan_port/tcp" comment 'Aurelia Server' >/dev/null
    ufw allow 5353/udp comment 'Aurelia Server discovery' >/dev/null
  fi
}

if [ "${1:-}" = --uninstall ]; then
  remove_data=false
  [ "${2:-}" = --remove-data ] && remove_data=true
  systemctl disable --now aurelia aurelia-autosleep.timer aurelia-start.socket aurelia-update-request.path \
    aurelia-update-check.timer 2>/dev/null || true
  systemctl disable aurelia-wake-on-lan.service 2>/dev/null || true
  rm -f "$unit" "$command_path" /etc/aurelia-autosleep.conf /etc/systemd/system/aurelia-autosleep.service \
    /etc/systemd/system/aurelia-autosleep.timer /etc/systemd/system/aurelia-wake-on-lan.service \
    /etc/systemd/system/aurelia-start.socket /etc/systemd/system/aurelia-start.service \
    /etc/systemd/system/aurelia-update-request.path /etc/systemd/system/aurelia-update-request.service \
    /etc/systemd/system/aurelia-update-check.timer /etc/systemd/system/aurelia-update-check.service \
    /etc/aurelia/github-token
  rmdir /etc/aurelia 2>/dev/null || true
  systemctl daemon-reload
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw delete allow "$lan_port/tcp" >/dev/null 2>&1 || true
    ufw delete allow 5353/udp >/dev/null 2>&1 || true
  fi
  rm -rf "$install_root"
  if $remove_data; then
    read -r -p "Delete the server data in $data_dir (accounts, library, progress)? [y/N] " answer
    case "$answer" in
      y|Y|yes|YES) rm -rf "$data_dir"; userdel aurelia 2>/dev/null || true; echo "Server data deleted." ;;
      *) echo "Server data kept in $data_dir." ;;
    esac
  else
    echo "Aurelia Server was removed. Its data stays in $data_dir."
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
    echo "Aurelia Server needs the ICU library (libicu). Install it with your package manager first." >&2
    exit 1
  fi
  echo "Installing $icu, which Aurelia Server needs..."
  apt-get install -y "$icu" >/dev/null
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

if ! id aurelia >/dev/null 2>&1; then
  useradd --system --user-group --home-dir "$data_dir" --no-create-home --shell /usr/sbin/nologin aurelia
fi
install -d -o aurelia -g aurelia -m 0700 "$data_dir"

updating=false
[ -d "$install_root/server" ] && updating=true
# A device connecting meanwhile must not start the program while it is replaced.
systemctl stop aurelia-start.socket aurelia 2>/dev/null || true

# The new program is copied next to the old one first, so a failed copy leaves the old one whole.
install -d -m 0755 "$install_root"
rm -rf "$install_root/server.new"
cp -R "$package_root/server" "$install_root/server.new"
chown -R root:root "$install_root/server.new"
chmod -R u=rwX,go=rX "$install_root/server.new"
chmod 0755 "$install_root/server.new/Aurelia.Server"
rm -rf "$install_root/server.old"
[ -d "$install_root/server" ] && mv "$install_root/server" "$install_root/server.old"
mv "$install_root/server.new" "$install_root/server"
rm -rf "$install_root/server.old"

rm -rf "$install_root/notices"
cp -R "$package_root/notices" "$install_root/notices"
install -m 0644 "$package_root/VERSION" "$install_root/VERSION"
# The GitHub repository that `aurelia update` downloads from, when the package was built from one.
[ -f "$package_root/REPOSITORY" ] && install -m 0644 "$package_root/REPOSITORY" "$install_root/REPOSITORY"
install -m 0755 "$package_root/install.sh" "$install_root/install.sh"
install -m 0755 "$package_root/aurelia" "$command_path"
install -m 0644 "$package_root/aurelia.service" "$unit"
# Wake-on-LAN is always allowed. Power saving stays as it was; it is turned on in the app's server
# settings or with `sudo aurelia sleep`.
install -m 0755 "$package_root/aurelia-autosleep" "$install_root/aurelia-autosleep"
install -m 0644 "$package_root/aurelia-sleep-settings" "$install_root/aurelia-sleep-settings"
install -m 0755 "$package_root/aurelia-wake-on-lan" "$install_root/aurelia-wake-on-lan"
for sleep_unit in aurelia-autosleep.service aurelia-autosleep.timer aurelia-wake-on-lan.service \
  aurelia-start.socket aurelia-start.service aurelia-update-request.path aurelia-update-request.service \
  aurelia-update-check.timer aurelia-update-check.service; do
  install -m 0644 "$package_root/$sleep_unit" "/etc/systemd/system/$sleep_unit"
done
chown -R root:root "$install_root/notices" "$install_root/VERSION" "$install_root/install.sh"

# Sleep settings used to be in /etc (1.8.2-1.8.3), with the timer's state as on/off. They move
# to the data folder, where the app can change them; the timer then runs always.
settings="$data_dir/sleep-settings"
if [ ! -e "$settings" ]; then
  . "$install_root/aurelia-sleep-settings"
  read_sleep_settings /etc/aurelia-autosleep.conf
  MODE=off
  systemctl is-enabled --quiet aurelia-autosleep.timer 2>/dev/null && MODE=sleep
  write_sleep_settings "$settings"
fi
rm -f /etc/aurelia-autosleep.conf

systemctl daemon-reload
systemctl enable aurelia >/dev/null
systemctl start aurelia
systemctl enable --now aurelia-wake-on-lan.service >/dev/null 2>&1 || true
systemctl enable --now aurelia-autosleep.timer >/dev/null
# Aurelia on a Mac can ask for an update check or an update; the server looks once a day by itself.
systemctl enable --now aurelia-update-request.path aurelia-update-check.timer >/dev/null 2>&1
firewall

echo "Aurelia Server $(cat "$install_root/VERSION") is installed and runs as a service."
if $updating; then
  echo "It was updated; accounts, library and settings are unchanged."
else
  echo "Set it up next with: sudo aurelia setup"
fi
