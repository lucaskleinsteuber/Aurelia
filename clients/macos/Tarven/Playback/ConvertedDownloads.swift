import Foundation

/// What a title can be downloaded as ("converted-downloads-v1", server 2.20.0): the original, or a
/// smaller copy the server converts live. Only this Mac keeps the copy (owner's decision, 15.11.2026).
struct DownloadOptionsResponse: Codable, Equatable, Sendable {
  let originalBytes: Int64
  let durationSeconds: Double?
  let canConvert: Bool
  let qualities: [DownloadQualityOption]
  let audioTracks: [DownloadAudioTrack]
  let audioTrack: Int?
}

struct DownloadQualityOption: Codable, Equatable, Identifiable, Sendable {
  let id: String
  let width: Int
  let height: Int
  let estimatedBytes: Int64
  let estimatedSeconds: Int?
}

struct DownloadAudioTrack: Codable, Equatable, Identifiable, Sendable {
  let index: Int
  let format: String
  let channels: Int
  let language: String?
  let title: String?
  let isDefault: Bool

  var id: Int { index }
}

/// What a download does with this Mac's quality setting.
enum DownloadChoice: Equatable, Sendable {
  case ask
  case original
  case converted(String)
}

/// The quality downloads use unless the person chooses each time; kept on this Mac.
enum DownloadQualityPreference {
  static let key = "TarvenDownloadQuality"
  static let ask = "ask"
  static let original = "original"
  static let choices: [(id: String, title: String)] = [
    (ask, "Ask Every Time"), (original, "Original"), ("1080p", "1080p"), ("720p", "720p"),
    ("480p", "480p"),
  ]
  private static let order = ["1080p", "720p", "480p", "360p"]

  /// The choice for one title: the original when nothing smaller is offered; otherwise the chosen
  /// quality, the next smaller one the title has, or its smallest.
  static func resolve(_ preference: String, options: DownloadOptionsResponse?) -> DownloadChoice {
    guard let options, options.canConvert, !options.qualities.isEmpty else { return .original }
    if preference == original { return .original }
    guard let wanted = order.firstIndex(of: preference) else { return .ask }
    let offered = options.qualities.map(\.id)
    if let match = offered.first(where: { (order.firstIndex(of: $0) ?? 0) >= wanted }) {
      return .converted(match)
    }
    return .converted(offered[offered.count - 1])
  }
}

/// The words the quality choice shows.
enum DownloadText {
  /// "18 GB", "1.8 GB", "640 MB".
  static func size(_ bytes: Int64) -> String {
    let value = Double(bytes)
    if value >= 10e9 { return "\(Int((value / 1e9).rounded())) GB" }
    if value >= 1e9 { return String(format: "%.1f GB", value / 1e9) }
    return "\(max(1, Int((value / 1e6).rounded()))) MB"
  }

  /// "about 20 min", "about 1 h 40 min".
  static func time(_ seconds: Int) -> String {
    let minutes = max(1, Int((Double(seconds) / 60).rounded()))
    if minutes < 60 { return "about \(minutes) min" }
    let rest = minutes % 60
    return "about \(minutes / 60) h" + (rest > 0 ? " \(rest) min" : "")
  }

  /// "About 1.8 GB · the server needs about 20 min".
  static func detail(_ quality: DownloadQualityOption) -> String {
    var text = "About \(size(quality.estimatedBytes))"
    if let seconds = quality.estimatedSeconds { text += " · the server needs \(time(seconds))" }
    return text
  }

  /// "English · 5.1", "Track 2 · Stereo".
  static func audio(_ track: DownloadAudioTrack) -> String {
    let name =
      track.title?.isEmpty == false
      ? track.title!
      : track.language.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
        ?? "Track \(track.index)"
    let layout =
      track.channels >= 6 ? "\(track.channels - 1).1" : track.channels == 1 ? "Mono" : "Stereo"
    return "\(name) · \(layout)"
  }
}

/// How a converted download is fetched: the quality's init and then every media segment, in
/// order, written one after another as a single fragmented MP4. Pure, so tests check it.
enum ConvertedDownloadPlan {
  /// The media segments a quality's playlist lists.
  static func segmentCount(playlist: String) -> Int {
    playlist.split(whereSeparator: \.isNewline).filter { line in
      !line.hasPrefix("#") && line.contains(".m4s")
    }.count
  }

  /// "/api/v1/streams/…/hls/720p/3.m4s?audio=1&purpose=download".
  static func piecePath(streamPath: String, quality: String, piece: String, audio: Int?) -> String {
    let query = (audio.map { "audio=\($0)&" } ?? "") + "purpose=download"
    return "\(streamPath)/hls/\(quality)/\(piece)?\(query)"
  }

  /// How long to wait before asking again, or nil to give up: the server is busy converting for
  /// someone who watches (429), restarting (503) or slow (timeouts); other answers end the download.
  static func retryDelay(status: Int?, retryAfter: TimeInterval?, attempt: Int) -> TimeInterval? {
    switch status {
    case 429, 503: return min(60, max(2, retryAfter ?? 5))
    case nil, 408, 500, 502, 504: return attempt < 8 ? min(30, pow(2, Double(attempt))) : nil
    default: return nil
    }
  }

  /// A server busy for others is waited for this long at most before the download stops.
  static let longestWait: TimeInterval = 30 * 60
}

/// Downloads a converted copy through the pinned connection, renewing the ticket when it ends.
struct ConvertedFileDownload {
  let api: APIClient
  let mediaId: UUID
  let quality: String
  let audio: Int?

  /// Writes the copy to `destination` and returns its size; `ticket` is the latest ticket used.
  func run(
    ticket initial: PlaybackSourceResponse, into destination: URL,
    progress: @escaping @Sendable (Double) -> Void,
    renewed changed: @escaping @MainActor @Sendable (PlaybackSourceResponse) -> Void
  ) async throws -> Int64 {
    var ticket = initial
    func fetch(_ piece: String) async throws -> Data {
      var attempt = 0
      var waited: TimeInterval = 0
      var renewed = false
      while true {
        try Task.checkCancellation()
        do {
          return try await api.downloadPiece(
            streamPath: ticket.streamPath, quality: quality, piece: piece, audio: audio)
        } catch let failure as APIClientError {
          if failure.httpStatus == 401 || failure.httpStatus == 404, !renewed,
            failure.problemCode != "segment_not_found"
          {
            // The ticket ended (after 12 hours, or the server restarted): a new one goes on.
            ticket = try await api.createPlayback(mediaId: mediaId, forDownload: true)
            await changed(ticket)
            renewed = true
            continue
          }
          guard
            let delay = ConvertedDownloadPlan.retryDelay(
              status: failure.httpStatus, retryAfter: failure.retryDelay, attempt: attempt),
            waited + delay <= ConvertedDownloadPlan.longestWait
          else { throw failure }
          attempt += 1
          waited += delay
          try await Task.sleep(for: .seconds(delay))
        } catch let failure as URLError where failure.code != .cancelled {
          guard
            let delay = ConvertedDownloadPlan.retryDelay(
              status: nil, retryAfter: nil, attempt: attempt)
          else { throw failure }
          attempt += 1
          try await Task.sleep(for: .seconds(delay))
        }
      }
    }

    let playlist = String(decoding: try await fetch("index.m3u8"), as: UTF8.self)
    let count = ConvertedDownloadPlan.segmentCount(playlist: playlist)
    guard count > 0 else { throw APIClientError.invalidResponse }
    FileManager.default.createFile(atPath: destination.path, contents: nil)
    let handle = try FileHandle(forWritingTo: destination)
    defer { try? handle.close() }
    var written: Int64 = 0
    let initData = try await fetch("init.mp4")
    try handle.write(contentsOf: initData)
    written += Int64(initData.count)
    for index in 0..<count {
      let segment = try await fetch("\(index).m4s")
      try handle.write(contentsOf: segment)
      written += Int64(segment.count)
      progress(Double(index + 1) / Double(count))
    }
    try handle.synchronize()
    return written
  }
}
