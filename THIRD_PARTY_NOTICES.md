# Third-party notices

Tarven's own source is licensed under the [MIT License](LICENSE). The apps and the server include
or use the open-source components below, each under its own license. Every app shows these license
texts in *Settings › About*, and the packages carry them in full.

## Video playback

- **VLCKit 3.7.3** (Mac), **MobileVLCKit** (iPhone and iPad) and **TVVLCKit 3.7.3** (Apple TV)
  from the VideoLAN project decode and show video. They are licensed under the GNU Lesser General
  Public License version 2.1 or later. The complete license text from the pinned official binary
  package is included in each app (`VLCKit-COPYING.txt`, `MobileVLCKit-COPYING.txt`,
  `TVVLCKit-COPYING.txt`). Source and license information: <https://code.videolan.org/videolan/VLCKit>
- **Tarven for Linux** uses **LibVLCSharp** (LGPL 2.1 or later) with the distribution's own
  **libVLC**; the Flatpak brings libVLC and its decoder libraries, each under its own license,
  listed in the Flatpak's notices.

## FFmpeg

The Mac app's server includes ffmpeg and ffprobe 9.0.2 from the FFmpeg project for live
conversion in web browsers, in `Contents/Resources/Server/ffmpeg`. They are built from the
unmodified official source (<https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz>, SHA-256
`8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e`) by
`scripts/build-ffmpeg-macos.sh`, without GPL or non-free parts, and are licensed under the GNU
Lesser General Public License version 2.1 or later; the license text is beside them as
`COPYING.LGPLv2.1`. The Linux server and the Docker image use the distribution's own ffmpeg, which
Tarven does not distribute. Source and license information: <https://ffmpeg.org/legal.html>

## Speech recognition

The Mac app's server includes `whisper-cli` from **whisper.cpp 1.8.3** (with `ggml` and
`stb_vorbis` from its examples) for speech-to-subtitle generation and subtitle syncing, in
`Contents/Resources/Server/whisper`. It is built from the pinned official source
(<https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v1.8.3.tar.gz>, SHA-256
`870ba21409cdf66697dc4db15ebdb13bc67037d76c7cc63756c81471d8f1731a`) by
`scripts/build-whisper-macos.sh`, is licensed under the MIT License, and carries its complete
license text beside the binary at `Contents/Resources/Server/whisper/LICENSE`. The Linux server
and the Docker image use the distribution's own `whisper.cpp` package, which Tarven does not
distribute. Source and license information: <https://github.com/ggml-org/whisper.cpp>

## Server and Linux app

The server includes .NET and ASP.NET Core, Entity Framework Core, Microsoft.Data.Sqlite,
SkiaSharp, SQLitePCLRaw with SQLite, and Haukcode.Mdns. The Linux app additionally includes
Avalonia (MIT), Tmds.DBus (MIT), BouncyCastle (MIT) and the Inter font (SIL Open Font License 1.1). Release builds
include the resolved package metadata and the available upstream license and notice files: in the
Mac app under `Contents/Resources/ThirdPartyNotices`, in the Linux packages under
`/usr/share/doc/tarven-desktop/notices`, including the .NET runtime packs' complete notices and
Skia's third-party notices.

The checked-in Haukcode.Mdns license comes from upstream commit
`db212fc8e272e29212fe2147810757ca5b437ca4` (the 1.0.18 package revision, verified unchanged for
the bundled 1.0.22 package). SQLitePCLRaw's license and notice come from the 2.1.12 tag, commit
`ca835d21508bff43121c65081035840ac5006c4c` (verified unchanged for the bundled 2.1.13 packages).
Its upstream notice covers optional providers too; inclusion does not imply Tarven uses SQLCipher
or those providers.

## Services

Movie and series details and pictures can come from [TMDB](https://www.themoviedb.org) when the
server's owner turns it on with their own key; subtitles can come from
[OpenSubtitles](https://www.opensubtitles.com). This product uses the TMDB API but is not
endorsed or certified by TMDB, and Tarven is not endorsed by OpenSubtitles.
