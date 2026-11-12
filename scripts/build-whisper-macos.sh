#!/bin/zsh
# Builds whisper.cpp's whisper-cli (MIT) for the Mac app's server, universal for Apple Silicon and
# Intel, with the ggml libraries linked in and Apple's Metal for Apple Silicon. Prints the folder
# that holds whisper-cli. The source is pinned by version and SHA-256 and cached in Local/.
set -euo pipefail

repository_root=${0:A:h:h}
source "$repository_root/scripts/workspace-paths.sh"
sh "$repository_root/scripts/prune-workspace.sh"

version=1.8.3
sha256=870ba21409cdf66697dc4db15ebdb13bc67037d76c7cc63756c81471d8f1731a
minimum_macos=26.0
cache="$other_root/Package Cache/whisper"
archive="$cache/whisper.cpp-$version.tar.gz"
output="$cache/$version/universal"
configuration_hash=$(shasum -a 256 "$0" | cut -d ' ' -f 1)

if [[ -x "$output/whisper-cli" && "${1:-}" != --rebuild \
  && -f "$output/build-configuration.sha256" && "$(cat "$output/build-configuration.sha256")" == "$configuration_hash" ]]; then
  print -r -- "$output"
  exit 0
fi

mkdir -p "$cache"
if [[ ! -f "$archive" ]]; then
  print -u2 -r -- "Downloading whisper.cpp $version from GitHub..."
  curl --fail --location --silent --show-error --output "$archive.partial" \
    "https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v$version.tar.gz"
  mv "$archive.partial" "$archive"
fi
if ! print -r -- "$sha256  $archive" | shasum -a 256 -c - >/dev/null 2>&1; then
  rm -f "$archive"
  print -u2 -r -- "The whisper.cpp $version source does not match its pinned SHA-256; it was removed."
  exit 1
fi

work=$(mktemp -d "$cache/work.XXXXXX")
trap 'rm -rf "$work"' EXIT
tar -xzf "$archive" -C "$work" --strip-components 1
# stb_vorbis checks for overflow with pointer arithmetic, which clang rightly calls always false;
# the same check by distance builds without a warning (warnings count as errors here).
python3 - "$work/examples/stb_vorbis.c" <<'PATCH'
import sys
path = sys.argv[1]
text = open(path, encoding="latin-1").read()
old = "if (f->stream_start + loc >= f->stream_end || f->stream_start + loc < f->stream_start) {"
new = "if (loc >= (unsigned int) (f->stream_end - f->stream_start)) {"
if old not in text:
    sys.exit("stb_vorbis.c changed; review the patch.")
open(path, "w", encoding="latin-1").write(text.replace(old, new))
PATCH

slices=()
for arch in arm64 x86_64; do
  print -u2 -r -- "Building whisper-cli $version for $arch..."
  build="$work/build-$arch"
  metal=OFF
  [[ "$arch" == arm64 ]] && metal=ON
  cmake -S "$work" -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET="$minimum_macos" \
    -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF -DWHISPER_SDL2=OFF \
    -DWHISPER_CURL=OFF -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF -DGGML_BLAS=OFF \
    -DGGML_METAL="$metal" -DGGML_METAL_EMBED_LIBRARY="$metal" >&2
  cmake --build "$build" --target whisper-cli -j "$(sysctl -n hw.ncpu)" >&2
  slices+=("$build/bin/whisper-cli")
done

rm -rf "$output"
mkdir -p "$output"
/usr/bin/lipo -create "${slices[@]}" -output "$output/whisper-cli"
cp "$work/LICENSE" "$output/LICENSE"
print -r -- "$configuration_hash" > "$output/build-configuration.sha256"
print -r -- "$output"
