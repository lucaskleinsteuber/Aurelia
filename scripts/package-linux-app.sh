#!/bin/bash
# Makes the Aurelia for Linux packages from the installed-layout archive that build-linux-app.sh
# writes. Runs on Linux and needs dpkg-deb, rpmbuild, makepkg, flatpak-builder (with the
# org.freedesktop Platform and Sdk 26.08) and bsdtar; a missing tool fails the run.
# AURELIA_LINUX_PACKAGE_FORMATS may select a space-separated subset (deb rpm arch flatpak) for
# intermediate test builds. Releases require all four. Flatpak modules are pinned beside this
# script in packaging/flatpak (or in clients/linux/packaging/flatpak in a checkout).
#   .deb  Ubuntu, Linux Mint, Debian, Pop!_OS
#   .rpm  Fedora, openSUSE
#   .pkg.tar.zst  Arch Linux, CachyOS, Manjaro, EndeavourOS
#   .flatpak  any distribution with Flatpak
# Usage: package-linux-app.sh <tree archive> <output directory> <version> <build>
set -euo pipefail
archive=$(realpath "${1:?Provide the installed-layout archive.}")
mkdir -p "${2:?Provide an output directory.}"
output=$(realpath "$2")
version=${3:?Provide the version.}
build=${4:?Provide the build number.}
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build" =~ ^[0-9]+$ ]] \
  || { echo "Use a MAJOR.MINOR.PATCH version and numeric build." >&2; exit 1; }
name=aurelia-desktop
app_id=io.github.lucasfd3.Aurelia
base="Aurelia-Desktop-$version-$build"
summary="Watch the movies and TV shows on your Aurelia server"
homepage=https://github.com/lucaskleinsteuber/Aurelia
formats="${AURELIA_LINUX_PACKAGE_FORMATS:-deb rpm arch flatpak}"
normalized_formats=''
for format in $formats; do
  case "$format" in deb|rpm|arch|flatpak) ;; *) echo "Unknown package format: $format" >&2; exit 1 ;; esac
  normalized_formats="$normalized_formats $format"
done
formats=${normalized_formats# }
selected() { case " $formats " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
required_tools=(bsdtar)
selected deb && required_tools+=(dpkg-deb)
selected rpm && required_tools+=(rpmbuild)
selected arch && required_tools+=(makepkg pacman)
selected flatpak && required_tools+=(flatpak flatpak-builder flock jq)
for tool in "${required_tools[@]}"; do
  command -v "$tool" >/dev/null || { echo "$tool is missing" >&2; exit 1; }
done
package_cache="${XDG_CACHE_HOME:-$HOME/.cache}/aurelia-package"
mkdir -p "$package_cache"
work=$(mktemp -d "$package_cache/work.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/tree"
bsdtar -xpf "$archive" -C "$work/tree"
archive_sha256=$(sha256sum "$archive" | cut -d ' ' -f1)
[ -x "$work/tree/usr/lib/aurelia-desktop/aurelia-desktop" ] \
  && [ -x "$work/tree/usr/lib/aurelia-desktop/server/Aurelia.Server" ] \
  && [ "$(cat "$work/tree/usr/lib/aurelia-desktop/VERSION")" = "$version ($build)" ] \
  || { echo "The archive is incomplete or has a different version." >&2; exit 1; }
size_kb=$(du -sk "$work/tree" | cut -f1)

# Debian and Ubuntu family. The .NET runtime is included; it needs ICU, whose package carries its
# version in the name.
icu_packages=$(printf 'libicu%s | ' 80 79 78 77 76 75 74 73 72 71 70)
if selected deb; then
mkdir -p "$work/deb/DEBIAN"
cp -a "$work/tree/usr" "$work/deb/"
cat > "$work/deb/DEBIAN/control" <<CONTROL
Package: $name
Version: $version-$build
Architecture: amd64
Maintainer: Aurelia <$homepage>
Installed-Size: $size_kb
Section: video
Priority: optional
Homepage: $homepage
Depends: libc6, libgcc-s1, libstdc++6, ${icu_packages% | }, libssl3t64 | libssl3, zlib1g, pkexec, libfontconfig1, libfreetype6, fonts-dejavu-core, libx11-6, libice6, libsm6, libwayland-client0, libwayland-cursor0, libwayland-egl1, libxkbcommon0, libegl1, libgl1, libvlc5 (>= 3.0), vlc-plugin-base, vlc-plugin-video-output
Recommends: ffmpeg
Description: $summary
 Browse and play your Aurelia library, manage your server and host a server
 on this computer. VLC is provided by the distribution. Install ffmpeg for
 browser conversion and server-generated scrub previews when hosting here.
CONTROL
dpkg-deb --root-owner-group -Zxz --build "$work/deb" "$output/$base-amd64.deb" >/dev/null
fi

# Fedora and openSUSE. Requirements are listed by hand, because the bundled .NET libraries would
# otherwise produce requirements no distribution provides.
if selected rpm; then
mkdir -p "$work/rpm"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
cat > "$work/rpm/SPECS/$name.spec" <<SPEC
Name: $name
Version: $version
Release: $build
Summary: $summary
License: MIT
URL: $homepage
ExclusiveArch: x86_64
AutoReqProv: no
Requires: glibc, libgcc, libstdc++, libicu, fontconfig, freetype, (libX11 or libX11-6), (libICE or libICE6), (libSM or libSM6), (libwayland-client or libwayland-client0), (libwayland-cursor or libwayland-cursor0), (libwayland-egl or libwayland-egl1), (libxkbcommon or libxkbcommon0), (libglvnd-egl or libEGL1)
Requires: (vlc-libs or libvlc5), (vlc-plugins-base or vlc-noX), (vlc-plugin-pulseaudio or vlc-noX)
Requires: (dejavu-sans-fonts or dejavu-fonts)
Requires: (openssl-libs or libopenssl3), (zlib or libz1), /usr/bin/pkexec
Recommends: ffmpeg
%global debug_package %{nil}
%global __os_install_post %{nil}
%global _build_id_links none

%description
Browse and play your Aurelia library, manage your server and host a server on this computer.
VLC is provided by the distribution. ffmpeg is recommended for browser conversion and previews.

%install
cp -a "$work/tree/usr" %{buildroot}/

%files
/usr/bin/$name
/usr/lib/$name
/usr/share/applications/$app_id.desktop
/usr/share/metainfo/$app_id.metainfo.xml
/usr/share/icons/hicolor/scalable/apps/$app_id.svg
%doc /usr/share/doc/$name
%license /usr/share/licenses/$name/LICENSE
SPEC
rpmbuild --quiet --define "_topdir $work/rpm" --define "_dbpath $work/rpm/db" -bb "$work/rpm/SPECS/$name.spec"
cp "$work/rpm/RPMS/x86_64/$name-$version-$build.x86_64.rpm" "$output/$base-x86_64.rpm"
fi

# Arch Linux family, with makepkg as an ordinary user.
if selected arch; then
mkdir -p "$work/arch"
cp "$archive" "$work/arch/tree.tar.gz"
cat > "$work/arch/PKGBUILD" <<PKGBUILD
pkgname=$name
pkgver=$version
pkgrel=$build
pkgdesc="$summary"
arch=(x86_64)
url="$homepage"
license=('MIT')
depends=(glibc gcc-libs icu openssl zlib polkit fontconfig freetype2 ttf-dejavu libx11 libice libsm wayland libxkbcommon libglvnd libvlc vlc-plugins-base vlc-plugin-ffmpeg vlc-plugin-pulse vlc-plugin-ass vlc-plugin-freetype)
optdepends=('ffmpeg: browser conversion and server-generated scrub previews when hosting here')
options=(!strip !debug)
source=(tree.tar.gz)
noextract=(tree.tar.gz)
sha256sums=($archive_sha256)
package() {
  bsdtar -xpf "\$srcdir/tree.tar.gz" -C "\$pkgdir"
}
PKGBUILD
(cd "$work/arch" && PKGDEST="$work/arch" PKGEXT=.pkg.tar.zst makepkg --force --noconfirm >/dev/null)
cp "$work/arch/$name-$version-$build-x86_64.pkg.tar.zst" "$output/$base-x86_64.pkg.tar.zst"
fi

# Flatpak, as one bundle file that installs the Freedesktop runtime from Flathub when needed.
if selected flatpak; then
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
flatpak_sources="$script_dir/../clients/linux/packaging/flatpak"
[ -d "$flatpak_sources" ] || flatpak_sources="$script_dir/packaging/flatpak"
[ -f "$flatpak_sources/io.github.lucasfd3.Aurelia.json" ] \
  || { echo "Missing the pinned Flatpak manifests beside the packaging script." >&2; exit 1; }
# Flatpak's module-cache identity includes the absolute manifest path. Keep that path stable
# between versions, and serialize access, so a new app build reuses unchanged decoder modules.
exec 9>"$package_cache/flatpak.lock"
flock 9
flatpak_work="$package_cache/flatpak-work"
rm -rf "$flatpak_work"
mkdir -p "$flatpak_work"
cp "$archive" "$flatpak_work/tree.tar.gz"
cp "$flatpak_sources/"* "$flatpak_work/"
# Local archive paths alone are not a reliable Flatpak cache key. Pin this exact tree's bytes
# in the generated manifest so a later version cannot reuse an older app module at that path.
jq --arg sha "$archive_sha256" \
  '(.modules[] | objects | select(.name == "aurelia-desktop") | .sources[] | select(.path == "tree.tar.gz") | .sha256) = $sha' \
  "$flatpak_work/$app_id.json" > "$flatpak_work/$app_id.json.tmp"
mv "$flatpak_work/$app_id.json.tmp" "$flatpak_work/$app_id.json"
flatpak_state="${AURELIA_FLATPAK_BUILD_STATE:-$package_cache/flatpak-builder}"
mkdir -p "$flatpak_state"
flatpak_log="$package_cache/flatpak-build.log"
(cd "$flatpak_work" && flatpak-builder --user --jobs=4 --state-dir="$flatpak_state" --disable-rofiles-fuse --force-clean --repo=repo build "$app_id.json") 2>&1 | tee "$flatpak_log"
if LC_ALL=C grep -Ein '(^|[^[:alnum:]_])warning([[:space:]:]|$)' "$flatpak_log"; then
  echo "The Flatpak dependency build contains warnings; no bundle will be made. See $flatpak_log." >&2
  exit 1
fi
installed="$flatpak_work/build/files/lib/aurelia-desktop"
[ "$(cat "$installed/VERSION")" = "$version ($build)" ] \
  || { echo "The Flatpak contains a different app version." >&2; exit 1; }
if [ -f "$work/tree/usr/lib/aurelia-desktop/aurelia-desktop.dll" ]; then
  cmp "$work/tree/usr/lib/aurelia-desktop/aurelia-desktop.dll" "$installed/aurelia-desktop.dll" \
    || { echo "The Flatpak app assembly does not match the supplied build." >&2; exit 1; }
fi
if [ -f "$work/tree/usr/lib/aurelia-desktop/SOURCE_COMMIT" ]; then
  cmp "$work/tree/usr/lib/aurelia-desktop/SOURCE_COMMIT" "$installed/SOURCE_COMMIT" \
    || { echo "The Flatpak source revision does not match the supplied build." >&2; exit 1; }
fi
flatpak build-bundle --runtime-repo=https://dl.flathub.org/repo/flathub.flatpakrepo \
  "$flatpak_work/repo" "$output/$base-x86_64.flatpak" "$app_id"
rm -rf "$flatpak_work"
fi

ls -l "$output"
