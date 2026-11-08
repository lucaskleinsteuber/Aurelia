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
}
