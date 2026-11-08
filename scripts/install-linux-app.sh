#!/bin/bash
# Installs a built Aurelia for Linux package on a Linux computer over ssh, with that distribution's
# own package manager (pacman, apt or dnf/zypper). Only the package is replaced; the app's settings
# in the user's home folder stay. The remote account needs sudo without a password prompt.
# Usage: install-linux-app.sh <ssh host> [build folder]   (AURELIA_LINUX_PACKAGE_SSH_CONFIG as for building)
set -euo pipefail
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repository_root/scripts/workspace-paths.sh"
host=${1:?Provide the ssh host.}
folder=${2:-$(ls -td "$other_root/Build/LinuxApp"/*/ 2>/dev/null | head -1)}
[ -d "$folder" ] || { echo "No Aurelia for Linux build found." >&2; exit 1; }
ssh_options=(-o BatchMode=yes)
[ -z "${AURELIA_LINUX_PACKAGE_SSH_CONFIG:-}" ] || ssh_options+=(-F "$AURELIA_LINUX_PACKAGE_SSH_CONFIG")

manager=$(ssh "${ssh_options[@]}" "$host" 'bash -c "for m in pacman apt-get dnf zypper; do command -v \$m >/dev/null && { echo \$m; exit; }; done"')
# The package for the remote computer's processor: x86_64/amd64 or aarch64/arm64.
case "$(ssh "${ssh_options[@]}" "$host" uname -m)" in
  aarch64 | arm64) arch=aarch64; deb_arch=arm64 ;;
  *) arch=x86_64; deb_arch=amd64 ;;
esac
case "$manager" in
  pacman) package=$(ls "$folder"/*-"$arch".pkg.tar.zst) ;;
  apt-get) package=$(ls "$folder"/*-"$deb_arch".deb) ;;
  dnf | zypper) package=$(ls "$folder"/*-"$arch".rpm) ;;
  *) echo "No supported package manager on $host." >&2; exit 1 ;;
esac
remote="/tmp/${package##*/}"
scp -q "${ssh_options[@]}" "$package" "$host:$remote"
case "$manager" in
  pacman) command="sudo -n pacman -U --noconfirm '$remote'" ;;
  apt-get) command="sudo -n apt-get install -y '$remote'" ;;
  dnf) command="sudo -n dnf install -y '$remote'" ;;
  zypper) command="sudo -n zypper --non-interactive install --allow-unsigned-rpm '$remote'" ;;
esac
ssh "${ssh_options[@]}" "$host" "bash -c \"$command; status=\\\$?; rm -f '$remote'; exit \\\$status\""
echo "Installed: $(ssh "${ssh_options[@]}" "$host" 'cat /usr/lib/aurelia-desktop/VERSION')"
