#!/bin/sh
# Feature probes run normally; every actual C compilation must then be warning-free.
set -eu
./configure --prefix=/app --libdir=/app/lib --disable-static --enable-fontconfig
find . -name Makefile -type f -exec sed -i '/^CFLAGS = /s/$/ -Werror/' {} +
make -j"${FLATPAK_BUILDER_N_JOBS:-4}"
make install
