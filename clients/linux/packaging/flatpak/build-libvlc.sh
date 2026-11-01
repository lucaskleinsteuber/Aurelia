#!/bin/sh
set -eu
# VLC 3's supported C dialect is C11. Select it explicitly instead of inheriting a newer
# compiler's default and its different libc const-qualified overloads.
CC="${CC:-cc} -std=gnu11"
export CC
# Autoconf probes intentionally compile incomplete programs; -Werror there misidentifies libc
# capabilities with modern Clang. Configure normally, then require -Werror in every generated
# compile recipe. package-linux-app.sh separately rejects warnings in the whole builder log.
./configure --prefix=/app --libdir=/app/lib --disable-maintainer-mode "BUILDCC=${CC:-cc} -std=gnu99 -Werror" \
  --enable-debug --disable-static --disable-vlc --disable-qt --disable-skins2 \
  --disable-lua --disable-nls --disable-sout --disable-vlm \
  --disable-a52 --disable-dca --disable-mad --disable-libmpeg2 --disable-vdpau \
  --disable-dvdread --disable-dvdnav --disable-bluray --disable-chromecast \
  --disable-notify --disable-dbus --disable-gnutls --disable-secret --disable-kwallet \
  --disable-dc1394 --disable-linsys --disable-sftp --disable-v4l2 --disable-vcd \
  --disable-screen --disable-freerdp --disable-gst-decode --disable-jack \
  --disable-svg --disable-svgdec --disable-xcb --disable-xvideo --disable-wayland \
  --disable-sdl-image --disable-ncurses --disable-srt --disable-avahi --disable-udev \
  --disable-libplacebo --disable-addonmanagermodules \
  --disable-live555 --disable-dv1394 --disable-opencv --disable-smbclient --disable-nfs \
  --disable-decklink --disable-vnc --disable-gme --disable-sid --disable-mod \
  --disable-shine --disable-postproc --disable-twolame --disable-spatialaudio \
  --disable-x265 --disable-vpl --disable-fluidsynth --disable-fluidlite --disable-zvbi \
  --disable-aribsub --disable-aribb25 --disable-kate --disable-caca --disable-mmal \
  --disable-soxr --disable-chromaprint --disable-librist --disable-goom --disable-projectm \
  --disable-vsxu --disable-mtp --disable-upnp --disable-microdns \
  --enable-avcodec --enable-avformat --enable-swscale --enable-pulse \
  --enable-libass --enable-freetype --enable-matroska
find . -name Makefile -type f -exec sed -i \
  -e '/^CFLAGS = /s/$/ -Werror/' -e '/^CXXFLAGS = /s/$/ -Werror/' {} +
# Aurelia supplies its own controls, discovery and window. Keep the no-op interface for libVLC
# integrations, and omit VLC's desktop/remote-control interfaces, discovery services and music
# visualizers. File demuxers, decoders, subtitles, filters, memory output and VAAPI stay enabled.
# Place these before the first aggregate target: make expands prerequisites while reading it.
awk '
  /^all: / && !inserted {
    print "aurelia_unused_modules := $(filter-out libdummy_plugin.la,$(control_LTLIBRARIES)) $(sd_LTLIBRARIES) $(visu_LTLIBRARIES)"
    print "LTLIBRARIES := $(filter-out $(aurelia_unused_modules),$(LTLIBRARIES))"
    print "control_LTLIBRARIES = libdummy_plugin.la"
    print "sd_LTLIBRARIES ="
    print "visu_LTLIBRARIES ="
    inserted=1
  }
  { print }
  END { if (!inserted) exit 1 }
' modules/Makefile > modules/Makefile.aurelia
mv modules/Makefile.aurelia modules/Makefile
# Autoconf adds this complex-arithmetic compile option to CFLAGS, but Clang rejects it when
# the standalone cache generator is linked. Its metadata-only tool needs no such optimization;
# keep the option on the player libraries and keep -Werror on the generator itself.
cat >> bin/Makefile <<'AURELIA_CACHEGEN'
vlc-cache-gen: CFLAGS := $(filter-out -fcx-limited-range,$(CFLAGS))
AURELIA_CACHEGEN
# Link dependent components to the installed core metadata, so their final runtime paths are
# correct on the first link. Referencing the uninstalled build-tree .la would force libtool
# to rewrite every dependent library during installation.
make -C compat -j"${FLATPAK_BUILDER_N_JOBS:-4}"
make -C src -j"${FLATPAK_BUILDER_N_JOBS:-4}"
make -C src install-libLTLIBRARIES
for component in lib modules bin; do
  sed -i \
    -e 's@\$(top_builddir)/src/libvlccore\.la@/app/lib/libvlccore.la@g' \
    -e 's@\.\./src/libvlccore\.la@/app/lib/libvlccore.la@g' "$component/Makefile"
done
make -C lib -j"${FLATPAK_BUILDER_N_JOBS:-4}"
make -C lib install-libLTLIBRARIES
make -C modules -j"${FLATPAK_BUILDER_N_JOBS:-4}" install-pkglibLTLIBRARIES
# Pulse input/output share a dynamically linked helper in lib/vlc. Link both plugins to its
# installed metadata as well, instead of asking libtool to relink them at installation time.
sed -i \
  -e '/^libpulse_plugin_la_LIBADD = /s@libvlc_pulse\.la@/app/lib/vlc/libvlc_pulse.la@g' \
  -e '/^libpulsesrc_plugin_la_LIBADD = /s@libvlc_pulse\.la@/app/lib/vlc/libvlc_pulse.la@g' \
  modules/Makefile
sed -i \
  -e 's@\$(top_builddir)/lib/libvlc\.la@/app/lib/libvlc.la@g' \
  -e 's@\.\./lib/libvlc\.la@/app/lib/libvlc.la@g' bin/Makefile
make -j"${FLATPAK_BUILDER_N_JOBS:-4}"
make install
