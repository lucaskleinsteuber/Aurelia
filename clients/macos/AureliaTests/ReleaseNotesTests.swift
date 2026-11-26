import Testing

@testable import Aurelia

struct ReleaseNotesTests {
  private let changelog = """
    ## [Unreleased]

    ## Mac 1.34.0 (148) Beta - 07.11.2026

    ### Changed

    - Settings open **inside** the window.
    - Posters load `ahead` of scrolling.

    ## Linux Desktop 1.6.0 (17) Beta - 07.11.2026

    - Linux only.

    ## Mac 1.33.1 (147) Beta - 07.11.2026

    - Older change.
    """

  @Test
  func theNotesOfThisMacVersionComeWithoutMarkdown() {
    #expect(
      ReleaseNotes.changes(in: changelog, version: "1.34.0")
        == ["Settings open inside the window.", "Posters load ahead of scrolling."])
    #expect(ReleaseNotes.changes(in: changelog, version: "1.33.1") == ["Older change."])
    #expect(ReleaseNotes.changes(in: changelog, version: "1.34").isEmpty)
    #expect(ReleaseNotes.changes(in: nil, version: "1.34.0").isEmpty)
  }

  @Test
  func linkedAndCombinedChangelogHeadingsMatchExactMacVersions() {
    let linkedChangelog = """
      ## [Unreleased]

      - Unreleased note.

      ## [Mac 1.29.0 (141) Beta](https://example.com/releases/mac-1.29.0) - 01.11.2026

      ### Added

      - Linked heading note.

      ## [Server 2.12.0 (161), Mac 2.12.1 (170), iOS 1.4.0](https://example.com/releases/combined) - 05.11.2026

      - Combined heading note.
      """
    #expect(
      ReleaseNotes.changes(in: linkedChangelog, version: "1.29.0") == ["Linked heading note."])
    #expect(
      ReleaseNotes.changes(in: linkedChangelog, version: "2.12.1") == ["Combined heading note."])
    #expect(ReleaseNotes.changes(in: linkedChangelog, version: "2.12").isEmpty)
    #expect(ReleaseNotes.changes(in: linkedChangelog, version: "2.12.0").isEmpty)
    #expect(ReleaseNotes.changes(in: linkedChangelog, version: "2.27.0").isEmpty)
  }
}
