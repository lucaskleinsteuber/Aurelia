# Aurelia iOS & iPadOS Native Client

Aurelia includes a dedicated, native client for iPhone and iPad in `clients/ios/`.

## Architecture & Constraints

1. **Independent Project & Codebase:**
   - In accordance with the AGENTS.md rules, `clients/ios/AureliaIOS.xcodeproj` is a completely isolated Xcode project with zero references to macOS or tvOS source trees or shared product libraries.
   - Independent release lifecycle and SemVer counter starting at **1.0.0 (1)**, configured via `clients/ios/Configuration/BuildNumber.xcconfig`.
   - Built with Swift 6 and strict concurrency checking (`SWIFT_STRICT_CONCURRENCY = complete`), passing all builds and logic tests warning-free.

2. **Universal Design & Interface:**
   - **iPhone:** Clean, focused four-tab bar (`Home`, `Library`, `Search`, `Settings`).
   - **iPad:** Native `NavigationSplitView` sidebar providing full multi-column browsing and details inspection.
   - **Visual Language:** Translucent dark Aurelia design system respecting the safe area and status bar chrome.

3. **Secure Protocol & Discovery:**
   - **Bonjour Discovery:** Automatically browses `_aurelia._tcp` services using Network.framework's `NWBrowser`.
   - **TLS Pinning:** Pinning against the server's SPKI P-256 SHA-256 fingerprint, protecting against LAN man-in-the-middle attacks.
   - **Multi-Profile Support:** Profile picker grid with 4-digit PIN authentication sheets for restricted profiles.
   - **Wake-on-LAN:** Broadcasts UDP magic packets to wake sleeping Linux servers on demand.

4. **Playback Engine & Zero-Disk Loopback Relay:**
   - **Direct Playback:** Direct decoding of container media formats via official MobileVLCKit 3.7.3 (`scripts/prepare-ios-vlckit.sh`).
   - **Loopback Relay (`IOSStreamRelay`):** A lightweight, ephemeral in-memory HTTP proxy (`127.0.0.1`) that translates VLC's unauthenticated range requests into authenticated, pinned TLS requests to the Aurelia server.
   - **Zero Converted Video Storage:** Converted video or transcoded files are never written to disk or device flash storage.
   - **Sidecar Subtitles:** Dynamically mapped on the loopback relay (`/subtitles/{secret}/{index}`) and attached directly as VLC playback slaves.
   - **Scrub Previews & Up Next:** Live timeline scrub preview plan and automated countdown banner for episodic titles.

5. **Remote Playback & AirPlay:**
   - **Play on Device:** Directly command other active Aurelia clients (such as Apple TV or Mac) from the title detail screen.
   - **AirPlay:** Embedded `AVRoutePickerView` allowing system-level streaming to Apple TV or AirPlay 2 speakers.

## Scripts & Verification

- **Dependency Preparation:**
  ```bash
  sh scripts/prepare-ios-vlckit.sh
  ```
  Downloads, verifies SHA-256, and links the pinned MobileVLCKit xcframework into `clients/ios/Dependencies/`.

- **Host Logic Tests:**
  ```bash
  zsh scripts/test-ios-logic.sh
  ```
  Executes the host-executable unit test suite on macOS in sub-second time without needing simulator boots.

- **Simulator Release Build:**
  ```bash
  zsh scripts/build-ios.sh
  ```
  Builds the universal iOS/iPadOS simulator bundle warning-free in Release configuration.
