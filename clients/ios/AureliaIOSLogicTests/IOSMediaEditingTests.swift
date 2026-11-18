import Foundation
import Testing

/// The title editor on iPhone and iPad: the draft and its manual fields, the requests it sends,
/// subtitles, speech and the intro and credits trim rules. Invented titles and a fake server only.
@Suite struct IOSMediaEditingTests {
  private let fingerprint = String(repeating: "B", count: 64)
  private let media = UUID(uuidString: "75000000-0000-0000-0000-000000000001")!

  private var document: IOSMediaEditorDocument {
    var found = IOSMediaEditorValues()
    found.title = "Invented Film"
    found.releaseYear = 1999
    found.genres = ["Drama"]
    var current = found
    current.title = "Invented Film (Director's Cut)"
    return IOSMediaEditorDocument(
      mediaId: media, libraryId: UUID(), kind: .movie, revision: 7, values: current,
      overrideFields: ["title"], sourcePath: "/invented/Film.mkv",
      relativeSourcePath: "Film.mkv", automaticValues: found)
  }

  @Test func changesBecomeManualAndFoundValuesComeBack() {
    var draft = IOSMetadataDraft(document: document)
    #expect(!draft.isDirty && !draft.canSave)
    #expect(draft.isManual("title"))
    draft.setYear("19x87")
    #expect(draft.year == "1987" && draft.values.releaseYear == 1987)
    draft.add(" drama ", to: \.genres, field: "genres")
    #expect(draft.values.genres == ["Drama"], "a genre is added once, whatever its case")
    draft.add("Mystery", to: \.genres, field: "genres")
    #expect(draft.isManual("genres") && draft.canSave)
    draft.useAutomatic("title")
    #expect(draft.values.title == "Invented Film" && !draft.isManual("title"))
    let request = draft.request
    #expect(request?.revision == 7)
    #expect(request?.overrideFields == ["genres", "releaseYear"])
    #expect(request?.relativeSourcePath == nil)
  }

  @Test func problemsStopTheSave() {
    var draft = IOSMetadataDraft(document: document)
    draft.set(\.title, "   ", field: "title")
    draft.setRuntime("99999")
    draft.set(
      \.credits,
      [IOSEditorCredit(id: UUID(), name: " ", department: "Acting", job: nil, character: nil)],
      field: "credits")
    #expect(Set(draft.problems.keys) == ["title", "runtimeMinutes", "credits"])
    #expect(!draft.canSave && draft.request == nil)
  }

  @Test func theSaveSendsTrimmedValuesAndTheChosenFile() throws {
    var draft = IOSMetadataDraft(document: document)
    draft.set(\.overview, "  An invented story.  ", field: "overview")
    draft.source = "Other/Film.mkv"
    let request = try #require(draft.request)
    #expect(request.values.overview == "An invented story.")
    #expect(request.relativeSourcePath == "Other/Film.mkv")
    let json =
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
    #expect(
      (json?["values"] as? [String: Any])?["title"] as? String == "Invented Film (Director's Cut)")
  }

  @Test func savingGoesToTheEditorAndAConflictIsReported() async throws {
    let transport = EditingTransport(responses: [
      problem(409, "editor_conflict")
    ])
    let draft = IOSMetadataDraft(document: document)
    await #expect {
      _ = try await api(transport).saveMediaEditor(id: media, try #require(draft.request))
    } throws: { error in
      (error as? IOSCoreError)?.problemCode == "editor_conflict"
    }
    let request = try #require(await transport.requests.first)
    #expect(request.httpMethod == "PUT")
    #expect(request.url?.path == "/api/v1/media/\(media.uuidString.lowercased())/editor")
  }

  @Test func picturesAreUploadedAsJPEGBelowTheServersLimits() async throws {
    let transport = EditingTransport(responses: [
      raw(#"{"id":"75000000-0000-0000-0000-0000000000aa","path":"x","width":2000,"height":3000}"#)
    ])
    let uploaded = try await api(transport).uploadMediaEditorImage(id: media, jpeg: Data([1, 2]))
    #expect(uploaded.width == 2000)
    let request = try #require(await transport.requests.first)
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "image/jpeg")
    #expect(request.url?.path.hasSuffix("/editor/uploads") == true)
    let big = IOSEditorImage.uploadSize(width: 12_000, height: 8_000)
    #expect(big.width == 4_000 && big.height == 2_666)
    let small = IOSEditorImage.uploadSize(width: 800, height: 1_200)
    #expect(small.width == 800 && small.height == 1_200)
  }

  @Test func subtitleResultsSayWhatHelpsChoose() throws {
    let candidate = try JSONDecoder().decode(
      IOSSubtitleCandidate.self,
      from: Data(
        #"{"fileId":"9","language":"de","release":"Invented.Film.1999","hashMatch":true,"hearingImpaired":true,"foreignPartsOnly":false,"machineTranslated":false,"downloadCount":1204,"fromTrusted":false}"#
          .utf8))
    #expect(candidate.details.hasPrefix("Matches this file · SDH · "))
    #expect(candidate.download.fileId == "9" && candidate.download.hearingImpaired)
    #expect(IOSSubtitleLanguages.code(forTrack: "ger") == "de")
    #expect(IOSSubtitleLanguages.code(forTrack: "und") == nil)
    #expect(IOSSubtitleLanguages.name("de") == "German")
  }

  @Test func speechJobsReadLikeTheirState() throws {
    let info = try JSONDecoder().decode(
      IOSMediaSpeechInfo.self,
      from: Data(
        #"{"available":true,"modelReady":true,"job":{"mediaId":"75000000-0000-0000-0000-000000000001","title":"x","kind":"create","language":"de","state":"listening","progress":0.4,"pausedForPlayback":false,"message":null,"subtitleId":null}}"#
          .utf8))
    #expect(info.canListen)
    #expect(info.job?.isRunning == true)
    #expect(info.job?.statusText == "Listening… 40 %")
    let request = IOSStartSpeechRequest(
      kind: "sync", language: "en", audioIndex: 1, subtitleIndex: 3)
    let json =
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
    #expect(json?["subtitleIndex"] as? Int == 3 && json?["kind"] as? String == "sync")
  }

  @Test func trimRulesMatchTheMac() throws {
    let duration: Int64 = 2_700_000
    let intro = IOSSegmentTrim.span(part: .intro, duration: duration, start: nil, end: nil)
    #expect(intro == 0...720_000)
    let credits = IOSSegmentTrim.span(part: .credits, duration: duration, start: nil, end: nil)
    #expect(credits == 2_100_000...2_700_000)
    let clamped = IOSSegmentTrim.clamp(start: 500_000, end: 400_000, span: intro)
    #expect(clamped.end - clamped.start == 1_000)
    #expect(IOSSegmentTrim.label(255_300) == "4:15.3")
    #expect(IOSSegmentTrim.frames(in: 0...100_000, count: 4) == [12, 37, 62, 87])
    let segments = try JSONDecoder().decode(
      IOSMediaSegmentsDetail.self,
      from: Data(
        #"{"mediaId":"75000000-0000-0000-0000-000000000001","analyzed":true,"canAnalyze":true,"introStartMilliseconds":5000,"introEndMilliseconds":65000,"introSource":"detected","introConfidence":0.9,"creditsStartMilliseconds":null,"creditsSource":"none","creditsConfidence":0}"#
          .utf8))
    #expect(IOSMediaSegmentsDetail.sourceText(segments.introSource) == "Found by the server")
    #expect(IOSMediaSegmentsDetail.sourceText(segments.creditsSource) == "Not found")
  }

  // MARK: Helpers

  private func api(_ transport: EditingTransport) -> IOSAPIClient {
    let connection = IOSStoredConnection(
      serverID: UUID(), name: "Synthetic server",
      baseURL: URL(string: "https://fixture.invalid:43111")!, fingerprint: fingerprint,
      deviceToken: String(repeating: "D", count: 43), deviceSessionID: UUID())
    let session = IOSProfileSession(
      user: IOSUser(id: UUID(), username: "Owner", role: "owner"),
      sessionId: UUID(), token: String(repeating: "P", count: 43),
      expiresAt: "2099-01-01T00:00:00Z")
    return IOSAPIClient(connection: connection, session: session, transport: transport)
  }
  private func raw(_ text: String) -> IOSHTTPResponse {
    IOSHTTPResponse(
      statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(text.utf8),
      fingerprint: fingerprint)
  }
  private func problem(_ status: Int, _ code: String) -> IOSHTTPResponse {
    IOSHTTPResponse(
      statusCode: status, headers: ["Content-Type": "application/json"],
      body: Data(#"{"code":"\#(code)","message":"Synthetic refusal."}"#.utf8),
      fingerprint: fingerprint)
  }
}

private actor EditingTransport: IOSHTTPTransport {
  private var responses: [IOSHTTPResponse]
  private(set) var requests: [URLRequest] = []
  init(responses: [IOSHTTPResponse]) { self.responses = responses }
  func execute(_ request: URLRequest, trust: IOSTrustMode) async throws -> IOSHTTPResponse {
    requests.append(request)
    guard !responses.isEmpty else { throw IOSCoreError.invalidResponse }
    return responses.removeFirst()
  }
}
