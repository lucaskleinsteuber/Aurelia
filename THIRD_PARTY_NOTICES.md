# Third-party notices

The native macOS client uses VLCKit 3.7.3 from the VideoLAN project for media
decoding and rendering. VLCKit is licensed under the GNU Lesser General Public
License version 2.1 or later. The complete license text from the pinned official
binary package is included in `Aurelia.app` as `VLCKit-COPYING.txt`.

Source and license information: <https://code.videolan.org/videolan/VLCKit>

The bundled server also includes .NET / ASP.NET Core, Entity Framework Core,
Microsoft.Data.Sqlite, SkiaSharp, SQLitePCLRaw with SQLite, and Haukcode.Mdns.
Release builds include the resolved package metadata and available upstream
license/notice files under `Contents/Resources/ThirdPartyNotices`, including
the runtime packs' complete notices and Skia's third-party notices.

The checked-in Haukcode.Mdns license comes from upstream commit
`db212fc8e272e29212fe2147810757ca5b437ca4` (the 1.0.18 package revision).
SQLitePCLRaw's license and notice come from the 2.1.12 tag, commit
`ca835d21508bff43121c65081035840ac5006c4c`. Its upstream notice covers optional
providers too; inclusion does not imply Aurelia uses SQLCipher or those providers.

These notices do not choose a license for Aurelia's own source. Complete the
distribution/license review before publishing a public download.
