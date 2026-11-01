#!/bin/sh
# Configure feature probes may intentionally produce diagnostics. Enforce -Werror on every
# actual library compilation after probing, preserving all upstream and SDK compiler flags.
set -eu
./configure --prefix=/app --libdir=/app/lib \
  --cc=clang \
  --host-cc=clang \
  --enable-shared \
  --disable-static \
  --enable-pic \
  --disable-doc \
  --disable-programs \
  --disable-gpl \
  --disable-nonfree \
  --disable-autodetect \
  --disable-avdevice \
  --disable-avfilter \
  --disable-encoders \
  --disable-muxers \
  --enable-vaapi \
  --enable-libdrm
sed -i 's/^CFLAGS=/CFLAGS=-Werror /' ffbuild/config.mak
make -j"${FLATPAK_BUILDER_N_JOBS:-4}"
make install
