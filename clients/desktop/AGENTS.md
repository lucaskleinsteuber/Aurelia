# Desktop Client Rules

- The desktop client is named **Aurelia** and targets Windows 10/11 on x64 and ARM64 first,
  Linux later. It is a separate product with its own version and build counter in
  `clients/desktop/Directory.Build.props` (`Version`, `AureliaDesktopBuildNumber`). The
  approved first version is **0.0.1**, build **1**. Confirm versions with the user before
  changing them.
- It uses C# and Avalonia; package versions are pinned in the root
  `Directory.Packages.props`. Its tests use xUnit v3 (required by Avalonia's headless
  runner); the server tests stay on xUnit v2.
- Like the Mac app, it will bundle and host its own Aurelia server, and it can also connect
  to another server. Keep that server the shared .NET server in `src/`, never a fork.
- Follow the Mac app's design: canvas `#202326`, surface `#282C2F`, dark sidebar, white
  capsule primary button. Do not show controls for features that do not work yet as if
  they did.
- Verify with `scripts/test-desktop.sh` (headless; no window takes over the screen) and
  build with `scripts/build-desktop.sh`. Build output stays outside the checkout.
