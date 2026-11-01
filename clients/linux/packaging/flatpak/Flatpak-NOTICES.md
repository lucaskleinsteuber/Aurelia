# Aurelia for Linux: Flatpak components

The Flatpak includes libVLC 3.0.24 and its dynamically loaded plugins from VideoLAN. libVLC is
licensed under LGPL 2.1 or later; VLC also contains GPL 2 or later components. Both complete
license texts are in the `libvlc` folder. The unmodified source archive is available at
https://download.videolan.org/pub/videolan/vlc/3.0.24/vlc-3.0.24.tar.xz.

It includes FFmpeg 8.1.3 shared libraries, built with GPL and non-free components disabled,
licensed under LGPL 2.1 or later. No FFmpeg command-line programs are included. Source:
https://ffmpeg.org/releases/ffmpeg-8.1.3.tar.xz.

It includes libass 0.17.5 (ISC), libebml 1.4.5 (LGPL 2.1 or later) and libmatroska 1.7.1
(LGPL 2.1 or later). Their license texts are beside this file. Unmodified source archives:

- https://github.com/libass/libass/releases/download/0.17.5/libass-0.17.5.tar.xz
- https://dl.matroska.org/downloads/libebml/libebml-1.4.5.tar.xz
- https://dl.matroska.org/downloads/libmatroska/libmatroska-1.7.1.tar.xz

The exact module versions, SHA-256 hashes and configuration options are versioned in
`clients/linux/packaging/flatpak/` in Aurelia's source archive. Library binaries may
be replaced in a rebuilt Flatpak using that manifest. These notices do not choose a license
for Aurelia's own source. The Freedesktop runtime is installed separately by Flatpak.

The source patches in that folder are part of the build recipe. They preserve compiler
hardening, update dependency APIs, and correct the checked error paths described in each
patch. The build omits VLC's desktop controls, discovery services, capture inputs and music
visualizers because Aurelia supplies its own interface and server connection.
