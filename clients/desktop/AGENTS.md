# Desktop Client Rules

- The desktop client is named **Aurelia** and targets Windows 10/11 on x64 and ARM64 first,
  Linux later. It is a separate product with its own version and build counter in
  `clients/desktop/Directory.Build.props` (`Version`, `AureliaDesktopBuildNumber`). The
  approved version is **0.2.0**, build **6** (library tools, management and settings). Confirm
  versions with the user before changing them.
- It uses C# and Avalonia; package versions are pinned in the root
  `Directory.Packages.props`. Its tests use xUnit v3 (required by Avalonia's headless
  runner); the server tests stay on xUnit v2.
- Like the Mac app, it bundles and hosts its own Aurelia server (`server/` beside the app) and
  can also connect to another server. Keep that server the shared .NET server in `src/`,
  never a fork. `LocalServerHost` follows the Mac server host: a lifeline pipe, a private
  control channel on 127.0.0.1 with a secret path, HTTPS on 127.0.0.1 for the app itself,
  bounded automatic restarts and network trials that roll back unless confirmed.
- On Windows the hosted server uses the standalone server's data folder
  (`%LOCALAPPDATA%\Aurelia Server`) and ports 43110/43111. On macOS the desktop app is a
  development build: its server keeps `Aurelia Desktop/Server`, ports 43120/43121 and network
  access off by default, and never uses the Mac app's `Aurelia Server` data, ports or Bonjour.
- Closing the window keeps a set-up server running behind the notification-area icon when the
  person chose that (the Windows default, with start at sign-in through the person's own Run
  entry); Quit Aurelia stops it. One Aurelia runs per person (`AppInstance`: the mutex
  `AureliaDesktopRunning`, which the installer checks, and a pipe only this account can open for
  "open" and "quit"). Keep the PC awake only through a power request while the server runs.
- The installer (`clients/desktop/Installer/Aurelia.iss`, built by `scripts/build-desktop.sh`) installs
  for all users, opens Windows Firewall for the server on Private networks and the local subnet
  only, quits a running Aurelia with `--quit` before replacing it, and on uninstall removes the
  firewall rule and the Run entry but keeps the person's server data unless they answer Yes.
  Never delete media or anything outside `%LOCALAPPDATA%\Aurelia` and `%LOCALAPPDATA%\Aurelia Server`.
- Management (removing or editing titles, profiles, storage, import preview, maintenance,
  backups, metadata, diagnostics) is for the owner and administrators only. It unlocks with
  the Server Password (`ManagementAccess`) and asks again when the server answers
  `management_locked`; changes that the server guards need approval as in
  `AdministrationRules`, which must mirror the server's `ServerRequestGuard`. Tests never
  save provider tokens against the real server, because saving a TMDB token is checked online.
- Windows-specific server code (handle-checked media opens, file identities, the TLS key) is
  exercised under CrossOver's Wine with `scripts/test-server-wine.sh` and synthetic data only;
  state clearly that this is not a run on Windows.
- Follow the Mac app's design: canvas `#202326`, surface `#282C2F`, dark sidebar, white
  capsule primary button. Do not show controls for features that do not work yet as if
  they did.
- Connection logic lives in `Aurelia.Desktop.Core` without UI types and reuses
  `Aurelia.Contracts`; the Avalonia app only presents it. Credentials go to Windows DPAPI
  (current user) or, on macOS/Linux development builds, a private file in the app's own
  data folder (`Aurelia Desktop` on macOS), never the Mac app's keychain or data.
- Playback uses VLC through LibVLCSharp. Each build carries only its own VLC (Windows x64
  or ARM64, or the Mac's for development). VLC decodes into memory and the picture is drawn by
  Avalonia, so controls sit on top of it everywhere. VLC reads streams through
  `LoopbackStreamRelay` on 127.0.0.1; it never talks to the server directly. Never call VLC
  from its own event threads; `VlcVideoEngine` passes events on from the thread pool.
- Timeline previews follow the Mac rule: decoded live, kept only in memory, discarded with the
  title, read through a relay that marks them as previews.
- Verify with `scripts/test-desktop.sh` (headless; no window takes over the screen). Its
  end-to-end tests start the real server from the build output with synthetic accounts, a
  test TLS identity, loopback-only HTTPS and no Bonjour. Build with
  `scripts/build-desktop.sh`. Build output stays outside the checkout.
