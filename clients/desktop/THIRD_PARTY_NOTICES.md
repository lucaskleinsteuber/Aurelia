# Third-party notices: Aurelia for Windows

Aurelia for Windows plays video with **VLC** (libVLC 3.0.24 from the
`VideoLAN.LibVLC.Windows` package, used through **LibVLCSharp** 3.10.1). Both are
licensed under the GNU Lesser General Public License version 2.1 or later; the
complete license text is included as `LibVLC-LGPL-2.1.txt`. Some VLC modules are
under other free licenses. The source code for VLC is available from VideoLAN at
<https://code.videolan.org/videolan/vlc> and for LibVLCSharp at
<https://code.videolan.org/videolan/LibVLCSharp>. VLC's files are kept unmodified in
the `libvlc` folder, and LibVLCSharp as `LibVLCSharp.dll`, beside `Aurelia.exe`, where
they can be replaced.

The interface is built with **Avalonia** (MIT license), drawn with **SkiaSharp** and
**HarfBuzzSharp** (MIT license), and uses the **Inter** typeface (SIL Open Font
License 1.1, included as `Inter-OFL-1.1.txt`). The app and the bundled Aurelia Server
run on **.NET** (MIT license). The server also includes ASP.NET Core, Entity
Framework Core, Microsoft.Data.Sqlite, SQLitePCLRaw with SQLite, and Haukcode.Mdns.

The `App` and `Server` folders hold the resolved package metadata and the license and
notice files each package ships, read from the published dependency graph.

The installer is made with **Inno Setup** by Jordan Russell and Martijn Laan
(<https://jrsoftware.org/isinfo.php>).

These notices do not choose a license for Aurelia's own source. Complete the
distribution and license review before publishing a public download.
