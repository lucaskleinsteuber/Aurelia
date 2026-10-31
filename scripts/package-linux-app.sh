#!/bin/bash
# Makes the Aurelia for Linux packages from the installed-layout archive that build-linux-app.sh
# writes. Runs on Linux and needs dpkg-deb, rpmbuild, makepkg, flatpak-builder (with the
# org.freedesktop Platform and Sdk 26.08) and bsdtar; a missing tool fails the run.
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
name=aurelia-desktop
app_id=io.github.lucasfd3.Aurelia
base="Aurelia-Desktop-$version-$build"
summary="Watch the movies and TV shows on your Aurelia server"
homepage=https://github.com/lucasfd3/Aurelia
for tool in dpkg-deb rpmbuild makepkg flatpak flatpak-builder bsdtar; do
  command -v "$tool" >/dev/null || { echo "$tool is missing" >&2; exit 1; }
done
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/tree"
bsdtar -xpf "$archive" -C "$work/tree"
size_kb=$(du -sk "$work/tree" | cut -f1)

# Debian and Ubuntu family. The .NET runtime is included; it needs ICU, whose package carries its
# version in the name.
icu_packages=$(printf 'libicu%s | ' 80 79 78 77 76 75 74 73 72 71 70)
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
Depends: libc6, libgcc-s1, libstdc++6, ${icu_packages% | }, libfontconfig1, libfreetype6, libx11-6, libice6, libsm6, libwayland-client0, libwayland-cursor0, libwayland-egl1, libxkbcommon0, libegl1, libgl1
Description: $summary
 Aurelia is a self-hosted media server with native apps. This preview of
 Aurelia for Linux shows the app's design; connecting, the library and the
 player follow in later versions.
CONTROL
dpkg-deb --root-owner-group -Zxz --build "$work/deb" "$output/$base-amd64.deb" >/dev/null

# Fedora and openSUSE. Requirements are listed by hand, because the bundled .NET libraries would
# otherwise produce requirements no distribution provides.
mkdir -p "$work/rpm"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
cat > "$work/rpm/SPECS/$name.spec" <<SPEC
Name: $name
Version: $version
Release: $build
Summary: $summary
License: Unknown
URL: $homepage
ExclusiveArch: x86_64
AutoReqProv: no
Requires: glibc, libgcc, libstdc++, libicu, fontconfig, freetype, (libX11 or libX11-6), (libICE or libICE6), (libSM or libSM6), (libwayland-client or libwayland-client0), (libwayland-cursor or libwayland-cursor0), (libwayland-egl or libwayland-egl1), (libxkbcommon or libxkbcommon0), (libglvnd-egl or libEGL1)
%global debug_package %{nil}
%global __os_install_post %{nil}
%global _build_id_links none

%description
Aurelia is a self-hosted media server with native apps. This preview of Aurelia for Linux shows
the app's design; connecting, the library and the player follow in later versions.

%install
cp -a "$work/tree/usr" %{buildroot}/

%files
/usr/bin/$name
/usr/lib/$name
/usr/share/applications/$app_id.desktop
/usr/share/metainfo/$app_id.metainfo.xml
/usr/share/icons/hicolor/scalable/apps/$app_id.svg
%doc /usr/share/doc/$name
SPEC
rpmbuild --quiet --define "_topdir $work/rpm" --define "_dbpath $work/rpm/db" -bb "$work/rpm/SPECS/$name.spec"
cp "$work/rpm/RPMS/x86_64/$name-$version-$build.x86_64.rpm" "$output/$base-x86_64.rpm"

# Arch Linux family, with makepkg as an ordinary user.
mkdir -p "$work/arch"
cp "$archive" "$work/arch/tree.tar.gz"
cat > "$work/arch/PKGBUILD" <<PKGBUILD
pkgname=$name
pkgver=$version
pkgrel=$build
pkgdesc="$summary"
arch=(x86_64)
url="$homepage"
license=(unknown)
depends=(glibc gcc-libs icu fontconfig freetype2 libx11 libice libsm wayland libxkbcommon libglvnd)
options=(!strip !debug)
source=(tree.tar.gz)
noextract=(tree.tar.gz)
sha256sums=(SKIP)
package() {
  bsdtar -xpf "\$srcdir/tree.tar.gz" -C "\$pkgdir"
}
PKGBUILD
(cd "$work/arch" && PKGDEST="$work/arch" PKGEXT=.pkg.tar.zst makepkg --force --nodeps --noconfirm >/dev/null)
cp "$work/arch/$name-$version-$build-x86_64.pkg.tar.zst" "$output/$base-x86_64.pkg.tar.zst"

# Flatpak, as one bundle file that installs the Freedesktop runtime from Flathub when needed.
mkdir -p "$work/flatpak"
cp "$archive" "$work/flatpak/tree.tar.gz"
cat > "$work/flatpak/$app_id.yml" <<MANIFEST
app-id: $app_id
runtime: org.freedesktop.Platform
runtime-version: '26.08'
sdk: org.freedesktop.Sdk
command: $name
finish-args:
  - --share=network
  - --share=ipc
  - --socket=wayland
  - --socket=fallback-x11
  - --device=dri
modules:
  - name: $name
    buildsystem: simple
    sources:
      - type: archive
        path: tree.tar.gz
        strip-components: 1
    build-commands:
      - mkdir -p /app/lib /app/bin /app/share
      - cp -a lib/$name /app/lib/
      - ln -s ../lib/$name/$name /app/bin/$name
      - cp -a share/applications share/metainfo share/icons share/doc /app/share/
MANIFEST
(cd "$work/flatpak" && flatpak-builder --user --disable-rofiles-fuse --force-clean --repo=repo build "$app_id.yml" >/dev/null)
flatpak build-bundle --runtime-repo=https://dl.flathub.org/repo/flathub.flatpakrepo \
  "$work/flatpak/repo" "$output/$base-x86_64.flatpak" "$app_id"

ls -l "$output"
