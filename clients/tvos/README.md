# Aurelia for Apple TV

A native tvOS 26 client for an Aurelia server on your local network. Version
0.1 starts with server discovery, device approval on the Mac, profiles, a small
movie and series library, and fullscreen playback with saved progress.

Open `AureliaTV.xcodeproj` and select the **AureliaTV** scheme. The TV client has
its own project, bundle identifier and version; it does not share an application
library with the Mac client. Server and user administration remain on the Mac.

From the repository root:

```sh
scripts/prepare-tvvlckit.sh
scripts/build-tvos.sh --unsigned
scripts/test-tvos-logic.sh
```

For a device-signed build, omit `--unsigned`. If Xcode needs to fetch a matching
development profile, add `--allow-provisioning-updates`; an existing configured
Apple development account and the device's pairing are required. To select an
already paired Apple TV, add `--device <identifier>`. Together with provisioning
updates, this allows Xcode to register that selected device for development.
The build script builds for **Apple TV devices**, never a simulator, and does not install
or launch the application. `AURELIA_TV_BUILD_ROOT` can select an external output
directory. Generated files otherwise use `scripts/workspace-paths.sh` defaults.

The TV Home Screen icon and top shelf use the existing Aurelia brand mark in
a native TV asset catalog. No Mac source files are linked into the app.

TVVLCKit 3.7.3 comes from the [official VideoLAN production archive](https://download.videolan.org/cocoapods/prod/TVVLCKit-3.7.3-319ed2c0-79128878.tar.xz)
and is verified against the SHA-256 pinned in the preparation script. The cache
stays external; ignored `Dependencies` symlinks make the project portable.
`TVVLCKIT_ROOT` can override that dependency directory. The vendor license is
included in the app's resources.

The **AureliaTVLogicTests** scheme runs only platform-neutral TV logic directly
on the Mac without an app host or TVVLCKit. No simulator, automated UI or playback
tests are run. Actual remote navigation and playback are accepted separately by
the user on an Apple TV; a successful build alone does not verify them.
