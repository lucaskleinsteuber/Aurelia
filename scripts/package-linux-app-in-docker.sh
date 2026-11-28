#!/bin/bash
# Makes the Linux app's packages in a throwaway Arch Linux container, for a Linux computer that has
# Docker but not the packaging tools (the owner's server while the CachyOS laptop is off).
#
# Runs on that computer, in the folder build-linux-app.sh copied there (the archive,
# package-linux-app.sh and packaging/flatpak), with the same arguments as package-linux-app.sh:
#   package-linux-app-in-docker.sh <archive> <output> <version> <build> <x64|arm64>
#
# The container gets the lowest CPU weight and runs the packaging under nice and idle I/O priority,
# so a server running there keeps priority; it publishes no port and touches no other container.
# Flatpak's runtimes and module cache stay in the Docker volume "tarven-package-cache" so the next
# build reuses them; `docker volume rm tarven-package-cache` removes them. flatpak-builder needs
# its own sandbox (bubblewrap) inside the container, which is why the container is privileged.
set -euo pipefail

archive=${1:?Provide the archive.}
output=${2:?Provide the output folder.}
version=${3:?Provide the version.}
build=${4:?Provide the build number.}
linux_arch=${5:-x64}
here=$(cd "$(dirname "$0")" && pwd)
image=${TARVEN_PACKAGE_IMAGE:-archlinux:base-devel}
docker=(docker)
docker info >/dev/null 2>&1 || docker=(sudo -n docker)
"${docker[@]}" info >/dev/null 2>&1 || { echo "Docker isn't usable here (not running, or no permission)." >&2; exit 1; }
# The tree is prebuilt: an arm64 package is made with this computer's own tools, never emulated.
platform=linux/$(uname -m | sed -e s/x86_64/amd64/ -e s/aarch64/arm64/)

mkdir -p "$here/$output"
"${docker[@]}" pull --quiet --platform "$platform" "$image" >/dev/null
"${docker[@]}" run --rm --privileged --platform "$platform" \
  --name "tarven-package-$version-$build-$linux_arch" \
  --cpu-shares 64 --network bridge \
  -v "$here:/work" -v tarven-package-cache:/cache \
  -e TARVEN_LINUX_PACKAGE_FORMATS="${TARVEN_LINUX_PACKAGE_FORMATS:-deb rpm arch flatpak}" \
  -e ARCHIVE="$archive" -e OUTPUT="$output" -e VERSION="$version" -e BUILD="$build" -e LINUX_ARCH="$linux_arch" \
  "$image" bash -euo pipefail -c '
    # appstreamcli compose loads every libvips module; their libraries make the container match a
    # full Arch desktop, so compose prints no warnings (the Flatpak build refuses any).
    pacman -Syu --noconfirm --needed dpkg rpm-tools flatpak flatpak-builder jq libarchive util-linux \
      libheif imagemagick openslide poppler-glib >/dev/null
    # libheif loads its codec plugins too; their libraries are its optional dependencies.
    heif_codecs=$(LC_ALL=C pacman -Qi libheif | sed -n "/^Optional Deps/,/^Required By/p" | grep -v "^Required By" \
      | sed -e "s/^Optional Deps *: *//" -e "s/^ *//" | cut -d: -f1 | grep -vx None || true)
    [ -z "$heif_codecs" ] || pacman -S --noconfirm --needed --asdeps $heif_codecs >/dev/null
    useradd --create-home --uid 1000 builder 2>/dev/null || true
    mkdir -p /cache/home
    chown builder /cache /cache/home
    chown -R builder /work
    run() { su builder -s /bin/bash -c "export HOME=/cache/home XDG_CACHE_HOME=/cache; cd /work; $1"; }
    case " $TARVEN_LINUX_PACKAGE_FORMATS " in
      *" flatpak "*)
        manifest=packaging/flatpak/org.tarven.Tarven.json
        branch=$(jq -r ".\"runtime-version\"" "/work/$manifest")
        refs="org.freedesktop.Platform//$branch org.freedesktop.Sdk//$branch"
        for extension in $(jq -r ".\"sdk-extensions\"[]?" "/work/$manifest"); do refs="$refs $extension//$branch"; done
        run "flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo \
          && flatpak install --user --noninteractive -y flathub $refs >/dev/null"
        ;;
    esac
    run "nice -n 19 ionice -c 3 bash package-linux-app.sh \"$ARCHIVE\" \"$OUTPUT\" \"$VERSION\" \"$BUILD\" \"$LINUX_ARCH\""
    chown -R "$(stat -c %u /work/package-linux-app.sh):$(stat -c %g /work/package-linux-app.sh)" "/work/$OUTPUT"
  '
