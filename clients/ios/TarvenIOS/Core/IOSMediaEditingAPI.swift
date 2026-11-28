import Foundation

// The title editor's requests (IOSMediaEditing.swift), through `adminData` like every other
// administration request, so protected changes get their one-time approval.

extension IOSAPIClient {
  private func editor<Value: Decodable>(
    _ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil,
    contentType: String = "application/json", longRunning: Bool = false
  ) async throws -> Value {
    try Self.decodeAdmin(
      Value.self,
      data: await adminData(
        path, method: method, query: query, body: body, contentType: contentType,
        longRunning: longRunning))
  }

  private static func media(_ id: UUID) -> String { "/api/v1/media/\(id.uuidString.lowercased())" }

  // MARK: Metadata and artwork

  func mediaEditor(id: UUID) async throws -> IOSMediaEditorDocument {
    try await editor("\(Self.media(id))/editor")
  }

  func saveMediaEditor(id: UUID, _ request: IOSSaveMediaEditorRequest) async throws
    -> IOSMediaEditorDocument
  {
    try await editor(
      "\(Self.media(id))/editor", method: "PUT", body: JSONEncoder().encode(request),
      longRunning: true)
  }

  /// A picture for the title's poster or backdrop, as JPEG; it stays a draft until saved.
  func uploadMediaEditorImage(id: UUID, jpeg: Data) async throws -> IOSUploadedEditorImage {
    try await editor(
      "\(Self.media(id))/editor/uploads", method: "POST", body: jpeg, contentType: "image/jpeg",
      longRunning: true)
  }

  func discardMediaEditorImage(id: UUID, upload: UUID) async throws {
    _ = try await adminData(
      "\(Self.media(id))/editor/uploads/\(upload.uuidString.lowercased())", method: "DELETE")
  }

  /// The picture behind a draft upload or a stored artwork, for the preview.
  func mediaEditorImage(id: UUID, artwork: IOSEditorArtwork) async throws -> Data {
    if let upload = artwork.uploadId {
      return try await adminData(
        "\(Self.media(id))/editor/uploads/\(upload.uuidString.lowercased())")
    }
    guard let asset = artwork.assetId else { throw IOSCoreError.invalidResponse }
    return try await adminData("\(Self.media(id))/editor/artwork/\(asset.uuidString.lowercased())")
  }

  /// One folder of the title's storage location, to choose another video file.
  func mediaEditorFiles(id: UUID, path: String) async throws -> IOSServerFileListing {
    try await editor(
      "\(Self.media(id))/editor/files", query: [URLQueryItem(name: "path", value: path)])
  }

  // MARK: Subtitles

  func downloadedSubtitles(id: UUID) async throws -> [IOSDownloadedSubtitle] {
    try await editor("\(Self.media(id))/subtitles")
  }

  func searchSubtitles(id: UUID, language: String) async throws -> [IOSSubtitleCandidate] {
    try await editor(
      "\(Self.media(id))/subtitles/search",
      query: [URLQueryItem(name: "language", value: language)], longRunning: true)
  }

  func downloadSubtitle(id: UUID, _ request: IOSDownloadSubtitleRequest) async throws
    -> IOSDownloadedSubtitle
  {
    try await editor(
      "\(Self.media(id))/subtitles", method: "POST", body: JSONEncoder().encode(request),
      longRunning: true)
  }

  func removeSubtitle(id: UUID, subtitle: UUID) async throws {
    _ = try await adminData(
      "\(Self.media(id))/subtitles/\(subtitle.uuidString.lowercased())", method: "DELETE")
  }

  // MARK: Subtitles from speech

  func mediaSpeech(id: UUID) async throws -> IOSMediaSpeechInfo {
    try await editor("\(Self.media(id))/speech")
  }

  func startMediaSpeech(id: UUID, _ request: IOSStartSpeechRequest) async throws
    -> IOSMediaSpeechInfo
  {
    try await editor(
      "\(Self.media(id))/speech", method: "POST", body: JSONEncoder().encode(request))
  }

  func cancelMediaSpeech(id: UUID) async throws {
    _ = try await adminData("\(Self.media(id))/speech", method: "DELETE")
  }

  /// The title's sound tracks and subtitle tracks, read with a short-lived playback ticket.
  func speechTracks(id: UUID) async throws -> (
    audio: [IOSSpeechAudioTrack], subtitles: [IOSLiveSubtitleTrack]
  ) {
    let ticket = try await createTicket(mediaID: id)
    defer { Task { [self] in try? await revokeTicket(id: ticket.id) } }
    let audio: IOSSpeechAudioTracksResponse = try await editor(
      "\(ticket.streamPath)/speech-audio/tracks")
    let subtitles = (try? await streamSubtitles(ticketID: ticket.id)) ?? []
    return (audio.tracks, subtitles.filter { $0.supported != false })
  }

  // MARK: Intro and credits

  /// How long the title is: from its progress once it was played, else as the server reads it.
  func mediaDuration(id: UUID) async throws -> Int64 {
    if let progress = try? await progress(mediaID: id), progress.durationMilliseconds > 0 {
      return progress.durationMilliseconds
    }
    let ticket = try await createTicket(mediaID: id)
    defer { Task { [self] in try? await revokeTicket(id: ticket.id) } }
    if ticket.progress.durationMilliseconds > 0 { return ticket.progress.durationMilliseconds }
    let audio: IOSSpeechAudioTracksResponse = try await editor(
      "\(ticket.streamPath)/speech-audio/tracks")
    return Int64((audio.durationSeconds ?? 0) * 1_000)
  }

  func mediaSegments(id: UUID) async throws -> IOSMediaSegmentsDetail {
    try await editor("\(Self.media(id))/segments")
  }

  func setMediaSegments(id: UUID, _ request: IOSSetMediaSegmentsRequest) async throws
    -> IOSMediaSegmentsDetail
  {
    try await editor(
      "\(Self.media(id))/segments", method: "PUT", body: JSONEncoder().encode(request))
  }

  func clearMediaSegments(id: UUID) async throws -> IOSMediaSegmentsDetail {
    try await editor("\(Self.media(id))/segments", method: "DELETE")
  }

  func reanalyzeMediaSegments(id: UUID) async throws {
    _ = try await adminData("\(Self.media(id))/segments/reanalyze", method: "POST")
  }
}
