# Aurelia for Linux: third-party notices

Aurelia for Linux is written in C# and runs on the .NET runtime, which is included in the
packages (MIT License). Its interface is drawn with Avalonia (MIT License) and SkiaSharp
(MIT License), and it uses the Inter typeface, licensed under the SIL Open Font License 1.1
(`Inter-OFL-1.1.txt`).

The folders beside this file hold the license and notice files of every .NET package in the
app, collected from its published dependency list.

The native deb, rpm and Arch packages use the distribution's libVLC and plugins, which the
package manager installs. The Flatpak includes its own pinned libVLC and codec libraries;
their versions, source links and complete licenses are in `Flatpak.md` and the folders beside it.

These notices do not choose a license for Aurelia's own source.
