import CoreGraphics
import Foundation
import Testing

@Suite("iPhone and iPad catch-up: chapters, notes, photo, Movie Night, collections")
struct IOSParityTests {
  private let chapters = [
    IOSPlaybackChapter(index: 0, title: "Opening", timeOffsetMilliseconds: 0, durationMilliseconds: 60_000),
    IOSPlaybackChapter(index: 1, title: "Middle", timeOffsetMilliseconds: 600_000, durationMilliseconds: 60_000),
    IOSPlaybackChapter(index: 2, title: "End", timeOffsetMilliseconds: 1_200_000, durationMilliseconds: 60_000),
  ]

  @Test func theCurrentChapterIsTheLastOneThatBegan() {
    #expect(IOSChapterPolicy.current(chapters, position: 10_000)?.title == "Opening")
    #expect(IOSChapterPolicy.current(chapters, position: 600_000)?.title == "Middle")
    #expect(IOSChapterPolicy.current(chapters, position: 1_500_000)?.title == "End")
    #expect(IOSChapterPolicy.current([], position: 1) == nil)
  }

  @Test func chapterMarksLeaveOutTheStartAndNeedTwoChapters() {
    #expect(IOSChapterPolicy.markers(chapters, duration: 2_400_000) == [0.25, 0.5])
    #expect(IOSChapterPolicy.markers(Array(chapters.prefix(1)), duration: 2_400_000).isEmpty)
    #expect(IOSChapterPolicy.markers(chapters, duration: 0).isEmpty)
  }

  @Test func sceneNotesShowAtTheirMomentOrRange() {
    let media = UUID()
    let moment = IOSSceneNote(
      id: UUID(), mediaId: media, startMilliseconds: 60_000, endMilliseconds: nil, text: "Look",
      revision: 1)
    let range = IOSSceneNote(
      id: UUID(), mediaId: media, startMilliseconds: 120_000, endMilliseconds: 180_000,
      text: "Chase", revision: 2)
    #expect(IOSSceneNotePolicy.cue([moment, range], position: 59_000) == nil)
    #expect(IOSSceneNotePolicy.cue([moment, range], position: 65_000) == moment)
    #expect(IOSSceneNotePolicy.cue([moment, range], position: 67_000) == nil)
    #expect(IOSSceneNotePolicy.cue([moment, range], position: 170_000) == range)
    #expect(IOSSceneNotePolicy.cleaned("  ") == nil)
    #expect(IOSSceneNotePolicy.cleaned(String(repeating: "a", count: 3_000))?.count == 2_000)
    #expect(IOSSceneNotePolicy.label(range) == "2:00–3:00")
    #expect(IOSSceneNotePolicy.label(moment) == "1:00")
  }

  @Test func aPhotoCropIsASquareInsideThePhoto() {
    let size = CGSize(width: 4_000, height: 3_000)
    let whole = IOSPhotoCrop.rect(imageSize: size, side: 300, zoom: 1, offset: .zero)
    #expect(whole.width == 3_000 && whole.height == 3_000)
    #expect(whole.minX == 500 && whole.minY == 0)
    let zoomed = IOSPhotoCrop.rect(imageSize: size, side: 300, zoom: 2, offset: CGSize(width: 10_000, height: 0))
    #expect(zoomed.width == 1_500)
    #expect(zoomed.minX == 0)
    let clamped = IOSPhotoCrop.clamped(offset: CGSize(width: 900, height: 900), imageSize: size, side: 300, zoom: 1)
    #expect(clamped.width == 50 && clamped.height == 0)
  }

  @Test func tonightsProgramSummarizesTheHostsChoice() throws {
    let state = try JSONDecoder().decode(
      IOSMovieNightState.self,
      from: Data(
        """
        {"id":"00000000-0000-0000-0000-000000000001","phase":"lobby","revision":1,"round":0,
        "deckVersion":0,"kinds":"movies","genre":"Comedy","genreOptions":["Comedy"],"members":[],
        "deck":null,"yourVotes":[],"result":null,"lastAction":null,"lastActionBy":null,
        "era":"2010s","length":"short"}
        """.utf8))
    let program = IOSMovieNightProgram(state)
    #expect(program.summary == "Movies · Comedy · 2010s · Short")
    let encoded = try JSONEncoder().encode(program)
    let json = try #require(String(data: encoded, encoding: .utf8))
    #expect(json.contains("\"era\":\"2010s\""))
    #expect(IOSMovieNightProgram(kinds: "all", genre: nil, era: "any", length: "any").summary == "Movies and shows")
  }

  @Test func onlyOwnAndAdministeredCollectionsCanBeEdited() {
    let me = UUID()
    func collection(shared: Bool, smart: Bool = false, owner: UUID? = nil) -> IOSCollection {
      var value = IOSCollection(id: UUID(), name: "List", poster: nil, items: [], isSmart: smart, isShared: shared)
      value.userId = owner
      return value
    }
    #expect(IOSCollectionRules.canEdit(collection(shared: false, owner: me), userID: me, role: "user"))
    #expect(!IOSCollectionRules.canEdit(collection(shared: false, owner: UUID()), userID: me, role: "owner"))
    #expect(!IOSCollectionRules.canEdit(collection(shared: true), userID: me, role: "user"))
    #expect(IOSCollectionRules.canEdit(collection(shared: true), userID: me, role: "admin"))
    #expect(!IOSCollectionRules.canEdit(collection(shared: false, smart: true, owner: me), userID: me, role: "owner"))
    #expect(IOSCollectionRules.cleanedName("   ") == nil)
    #expect(IOSCollectionRules.cleanedName(" Friday ") == "Friday")
  }
}
