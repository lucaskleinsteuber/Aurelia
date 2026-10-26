#!/bin/zsh
# Builds the Mac server's own ffmpeg and ffprobe for live conversion in web browsers
# (docs/WEB_APP.md): LGPL only, with no GPL parts, universal (arm64 and x86_64) and with only
# what live conversion needs: the MKV, MP4, AVI and MPEG-TS readers, the decoders, the AAC
# encoder, Apple's VideoToolbox H.264 encoder, the MP4 writer and text subtitles as WebVTT.
#
# The official source from ffmpeg.org is checked against a fixed SHA-256 and kept in
# Local/Package Cache/ffmpeg. The result lands in Local/Package Cache/ffmpeg/<version>/universal:
# ffmpeg and ffprobe with the libav* libraries they share beside them (found through
# @loader_path). It is reused until the version changes (--rebuild builds it again).
# build-macos-release.sh copies the folder into the app and signs every file with the hardened
# runtime. The last line of output is the folder. Intel slices use nasm when installed
# (brew install nasm) and plain C otherwise.
set -euo pipefail

repository_root=${0:A:h:h}
source "$repository_root/scripts/workspace-paths.sh"
sh "$repository_root/scripts/prune-workspace.sh"

version=9.0.2
sha256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
minimum_macos=26.0
cache="$other_root/Package Cache/ffmpeg"
archive="$cache/ffmpeg-$version.tar.xz"
output="$cache/$version/universal"
configuration_hash=$(shasum -a 256 "$0" | cut -d ' ' -f 1)

if [[ -x "$output/ffmpeg" && -x "$output/ffprobe" && "${1:-}" != --rebuild \
  && -f "$output/build-configuration.sha256" && "$(cat "$output/build-configuration.sha256")" == "$configuration_hash" ]]; then
  print -r -- "$output"
  exit 0
fi

mkdir -p "$cache"
if [[ ! -f "$archive" ]]; then
  print -u2 -r -- "Downloading ffmpeg $version from ffmpeg.org..."
  curl --fail --location --silent --show-error --output "$archive.partial" "https://ffmpeg.org/releases/ffmpeg-$version.tar.xz"
  mv "$archive.partial" "$archive"
fi
if ! print -r -- "$sha256  $archive" | shasum -a 256 -c - >/dev/null 2>&1; then
  rm -f "$archive"
  print -u2 -r -- "The ffmpeg $version source does not match its pinned SHA-256; it was removed."
  exit 1
fi

work=$(mktemp -d "$cache/work.XXXXXX")
trap 'rm -rf "$work"' EXIT

configure_options=(
  --disable-everything --disable-autodetect --disable-doc --disable-debug --disable-network
  --disable-ffplay --disable-avdevice --enable-ffmpeg --enable-ffprobe
  --enable-shared --disable-static --install-name-dir=@rpath
  --enable-pthreads --enable-zlib --enable-videotoolbox
  --enable-protocol=file,pipe
  --enable-demuxer=matroska,mov,avi,mpegts
  --enable-muxer=mp4,mov,webvtt
  --enable-encoder=aac,h264_videotoolbox,webvtt
  --enable-decoder=h264,hevc,mpeg4,msmpeg4v1,msmpeg4v2,msmpeg4v3,mpeg1video,mpeg2video,vc1,wmv1,wmv2,wmv3,vp8,vp9,av1,mjpeg,h263,theora
  --enable-decoder=aac,aac_latm,ac3,eac3,dca,truehd,mlp,mp1,mp2,mp3,opus,vorbis,flac,alac,wmav1,wmav2,wmapro
  --enable-decoder=pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_f32le,pcm_u8,pcm_bluray,pcm_dvd
  --enable-decoder=srt,subrip,ass,ssa,movtext,webvtt,text
  --enable-parser=h264,hevc,mpeg4video,mpegvideo,vc1,vp8,vp9,av1,aac,aac_latm,ac3,dca,mlp,mpegaudio,opus,vorbis,flac
  --enable-bsfs
  --enable-filter=scale,format,aformat,aresample,anull,null,trim,atrim,setpts,asetpts,crop,transpose,hflip,vflip
)

for arch in arm64 x86_64; do
  print -u2 -r -- "Building ffmpeg $version for $arch..."
  source_root="$work/$arch"
  mkdir -p "$source_root"
  tar -xJf "$archive" -C "$source_root" --strip-components 1
  arch_options=(--arch="$arch" --cc="clang -arch $arch" --target-os=darwin
    --extra-cflags="-mmacosx-version-min=$minimum_macos"
    --extra-ldflags="-arch $arch -mmacosx-version-min=$minimum_macos -Wl,-rpath,@loader_path")
  if [[ "$arch" != "$(uname -m)" ]]; then arch_options+=(--enable-cross-compile); fi
  if [[ "$arch" == x86_64 ]]; then
    if command -v nasm >/dev/null 2>&1; then arch_options+=(--x86asmexe=nasm); else arch_options+=(--disable-x86asm); fi
  fi
  # The prefix is only a name inside the binary; nothing is installed there.
  (cd "$source_root" && ./configure --prefix=/opt/aurelia-ffmpeg "${configure_options[@]}" "${arch_options[@]}" >"$work/configure-$arch.log" 2>&1) || {
    tail -n 30 "$work/configure-$arch.log" >&2
    exit 1
  }
  if grep -q 'License: .*GPL' "$work/configure-$arch.log" && ! grep -q 'License: LGPL' "$work/configure-$arch.log"; then
    print -u2 -r -- "The $arch configuration is not LGPL."
    exit 1
  fi
  { make -C "$source_root" -j"$(sysctl -n hw.ncpu)" && make -C "$source_root" install DESTDIR="$work/root-$arch"; } \
    >"$work/make-$arch.log" 2>&1 || {
    tail -n 30 "$work/make-$arch.log" >&2
    exit 1
  }
done

staged="$output.new"
rm -rf "$staged"
mkdir -p "$staged"
installed=opt/aurelia-ffmpeg
for program in ffmpeg ffprobe; do
  lipo -create "$work/root-arm64/$installed/bin/$program" "$work/root-x86_64/$installed/bin/$program" -output "$staged/$program"
  chmod 0755 "$staged/$program"
done
# The libraries under the names the programs and libraries ask for, such as libavcodec.62.dylib.
for library in $(otool -L "$staged/ffmpeg" "$staged/ffprobe" | awk '$1 ~ /^@rpath\// {sub("@rpath/", "", $1); print $1}' | sort -u); do
  lipo -create "$(realpath "$work/root-arm64/$installed/lib/$library")" "$(realpath "$work/root-x86_64/$installed/lib/$library")" \
    -output "$staged/$library"
  chmod 0644 "$staged/$library"
done

# The license travels with the programs.
tar -xJf "$archive" -O "ffmpeg-$version/COPYING.LGPLv2.1" >"$staged/COPYING.LGPLv2.1"

# The binary must be LGPL, universal, self-contained and able to encode what live conversion uses.
[[ "$(lipo -archs "$staged/ffmpeg")" == "x86_64 arm64" ]] || { print -u2 "ffmpeg is not universal."; exit 1; }
"$staged/ffmpeg" -hide_banner -L 2>&1 | tr '\n' ' ' | grep -q 'GNU Lesser General Public *License' || { print -u2 "ffmpeg is not LGPL."; exit 1; }
encoders=$("$staged/ffmpeg" -hide_banner -encoders)
for encoder in aac h264_videotoolbox webvtt; do
  grep -qE "^ [A-Z.]{6} $encoder " <<<"$encoders" || { print -u2 -r -- "ffmpeg lacks the $encoder encoder."; exit 1; }
done
muxers=$("$staged/ffmpeg" -hide_banner -muxers)
grep -qE '^  E  webvtt ' <<<"$muxers" || { print -u2 "ffmpeg lacks the WebVTT writer."; exit 1; }
if otool -L "$staged"/ffmpeg "$staged"/ffprobe "$staged"/*.dylib | grep -v ':$' | awk '$1 !~ /^(\/System\/|\/usr\/lib\/|@rpath\/)/' | grep -q .; then
  print -u2 "ffmpeg links a library outside macOS."
  exit 1
fi

print -r -- "$configuration_hash" >"$staged/build-configuration.sha256"
rm -rf "$output"
mv "$staged" "$output"
if strings -a "$output"/* | grep -qF "$HOME"; then
  print -u2 "The ffmpeg build contains a local path."
  rm -rf "$output"
  exit 1
fi
print -u2 -r -- "ffmpeg $version is ready: $(du -sh "$output" | cut -f1) for both programs and their libraries."
print -r -- "$output"
