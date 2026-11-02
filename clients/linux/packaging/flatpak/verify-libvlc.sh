#!/bin/sh
set -eu
# Binary/module inspection only. This creates no player, media object, stream or decoder.
plugins=/app/lib/vlc/plugins
count=0
for module in \
  video_output/libvmem_plugin.so \
  access/libhttp_plugin.so \
  codec/libavcodec_plugin.so \
  codec/libvaapi_drm_plugin.so \
  demux/libmkv_plugin.so \
  demux/libmp4_plugin.so \
  video_chroma/libswscale_plugin.so \
  audio_output/libpulse_plugin.so \
  audio_filter/libcompressor_plugin.so \
  audio_filter/libequalizer_plugin.so \
  audio_filter/libscaletempo_plugin.so \
  codec/liblibass_plugin.so \
  text_renderer/libfreetype_plugin.so \
  codec/libsubsdec_plugin.so; do
  file="$plugins/$module"
  test -s "$file" || { echo "Missing required VLC module: $module" >&2; exit 1; }
  nm -D --defined-only "$file" | grep 'vlc_entry' >/dev/null \
    || { echo "Missing VLC entry point: $module" >&2; exit 1; }
  linked=$(ldd "$file")
  if printf '%s\n' "$linked" | grep 'not found'; then
    echo "An installed VLC module has unresolved dependencies: $module" >&2
    exit 1
  fi
  count=$((count + 1))
done
nm -D --defined-only /app/lib/libvlc.so.5 | grep 'libvlc_video_set_callbacks' >/dev/null \
  || { echo "The libVLC frame callback API is missing." >&2; exit 1; }
nm -D --defined-only /app/lib/libvlc.so.5 | grep 'libvlc_media_player_set_equalizer' >/dev/null \
  || { echo "The public VLC equalizer API is missing." >&2; exit 1; }
nm -D --defined-only /app/lib/libvlccore.so.9 | grep 'var_SetChecked' >/dev/null \
  || { echo "The VLC audio chain configuration entry point is missing." >&2; exit 1; }
echo "Verified $count required VLC modules, their entry points and linked libraries; no media opened."
