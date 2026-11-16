import CryptoKit
import Foundation

/// BGTask's expiration block has no actor or delivery-queue contract. Construct the outer
/// callback outside MainActor before handing it to the framework; the hop happens inside it.
enum IOSBackgroundTaskCallbacks {
  nonisolated static func expiration(
    onExpire: @escaping @MainActor @Sendable () -> Void
  ) -> @Sendable () -> Void {
    { Task { @MainActor in onExpire() } }
  }
}

// Smaller downloads ("converted-downloads-v1", server 2.20.0), copied from the Mac app, not shared.
// The server converts the copy live from its adaptive-streaming qualities; only this device keeps
// it (owner's decision, 15.11.2026).

struct IOSDownloadOptions: Codable, Equatable, Sendable {
  let originalBytes: Int64
  let durationSeconds: Double?
  let canConvert: Bool
  let qualities: [IOSDownloadQuality]
  let audioTracks: [IOSDownloadAudioTrack]
  let audioTrack: Int?
}

struct IOSDownloadQuality: Codable, Equatable, Identifiable, Sendable {
  let id: String
  let width: Int
  let height: Int
  let estimatedBytes: Int64
  let estimatedSeconds: Int?
}

struct IOSDownloadAudioTrack: Codable, Equatable, Identifiable, Sendable {
  let index: Int
  let format: String
  let channels: Int
  let language: String?
  let title: String?
  let isDefault: Bool

  var id: Int { index }
}

enum IOSDownloadChoice: Equatable, Sendable {
  case ask
  case original
  case converted(String)
}

/// The quality downloads use unless the person chooses each time; kept on this device.
enum IOSDownloadQualityPreference {
  static let key = "AureliaDownloadQuality"
  static let ask = "ask"
  static let original = "original"
  static let choices: [(id: String, title: String)] = [
    (ask, "Ask Every Time"), (original, "Original"), ("1080p", "1080p"), ("720p", "720p"),
    ("480p", "480p"),
  ]
  private static let order = ["1080p", "720p", "480p", "360p"]

  /// The original when nothing smaller is offered; otherwise the chosen quality, the next smaller
  /// one the title has, or its smallest.
  static func resolve(_ preference: String, options: IOSDownloadOptions) -> IOSDownloadChoice {
    guard options.canConvert, !options.qualities.isEmpty else { return .original }
    if preference == original { return .original }
    guard let wanted = order.firstIndex(of: preference) else { return .ask }
    let offered = options.qualities.map(\.id).sorted {
      let left = Int($0.dropLast()) ?? Int.max
      let right = Int($1.dropLast()) ?? Int.max
      return left == right ? $0 < $1 : left > right
    }
    let targetHeight = Int(order[wanted].dropLast()) ?? 0
    if let match = offered.first(where: { (Int($0.dropLast()) ?? Int.max) <= targetHeight }) {
      return .converted(match)
    }
    return .converted(offered[offered.count - 1])
  }

  /// A failed options request is a failure, never permission to download a larger original.
  nonisolated(nonsending) static func resolve(
    _ preference: String,
    loadingOptions: nonisolated(nonsending) () async throws -> IOSDownloadOptions
  ) async throws -> (choice: IOSDownloadChoice, options: IOSDownloadOptions) {
    let options = try await loadingOptions()
    return (resolve(preference, options: options), options)
  }
}

enum IOSDownloadText {
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

  /// "720p · about 1.8 GB".
  static func button(_ quality: IOSDownloadQuality) -> String {
    "\(quality.id) · about \(size(quality.estimatedBytes))"
  }
}

/// Where a converted download stands, saved after every segment so it continues after a stop.
struct IOSConvertedProgress: Codable, Equatable, Sendable {
  var quality: String
  var audio: Int?
  var segmentCount = 0
  var nextSegment = 0
  var writtenBytes: Int64 = 0
  /// The SHA-256 of the init segment the file starts with; another one means starting over.
  var initDigest: String?

  var share: Double { segmentCount > 0 ? min(1, Double(nextSegment) / Double(segmentCount)) : 0 }
}

/// How a converted download is fetched. Pure, so tests check it.
enum IOSConvertedDownloadPlan {
  static func segmentCount(playlist: String) -> Int {
    playlist.split(whereSeparator: \.isNewline).filter { line in
      !line.hasPrefix("#") && line.contains(".m4s")
    }.count
  }

  /// Only the server's HLS pieces: a quality such as "720p" and its playlist, init or segment.
  static func isValidPiece(quality: String, piece: String) -> Bool {
    quality.range(of: #"^[1-9][0-9]{2,3}p$"#, options: .regularExpression) != nil
      && piece.range(of: #"^(index\.m3u8|init\.mp4|[0-9]{1,6}\.m4s)$"#, options: .regularExpression)
        != nil
  }

  /// How long to wait before asking again, or nil to give up.
  static func retryDelay(status: Int?, retryAfter: TimeInterval?, attempt: Int) -> TimeInterval? {
    switch status {
    case 429, 503: return min(60, max(2, retryAfter ?? 5))
    case nil, 408, 500, 502, 504: return attempt < 8 ? min(30, pow(2, Double(attempt))) : nil
    default: return nil
    }
  }

  static let longestWait: TimeInterval = 30 * 60

  static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// Opens the partial file to continue: cut back to what was saved, or started again with the
  /// init when it is shorter than that, its init changed, or nothing was saved yet.
  static func prepare(_ url: URL, progress: inout IOSConvertedProgress, initData: Data) throws {
    let digest = digest(initData)
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? -1
    if progress.nextSegment > 0, progress.initDigest == digest, size >= progress.writtenBytes {
      let handle = try FileHandle(forWritingTo: url)
      try handle.truncate(atOffset: UInt64(progress.writtenBytes))
      try handle.close()
      return
    }
    try? FileManager.default.removeItem(at: url)
    guard
      FileManager.default.createFile(
        atPath: url.path, contents: initData,
        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    else { throw IOSOfflineError.notEnoughSpace }
    progress.nextSegment = 0
    progress.writtenBytes = Int64(initData.count)
    progress.initDigest = digest
  }
}

/// Fetches a converted copy segment by segment over the pinned connection.
struct IOSConvertedDownloader: Sendable {
  let api: IOSAPIClient
  let mediaID: UUID

  /// Continues `start` into `partial` and returns the finished size. `saved` hears every step;
  /// `renewed` a new ticket after the old one ended.
  func run(
    ticket initial: IOSPlaybackTicket, from start: IOSConvertedProgress, into partial: URL,
    saved: @escaping @Sendable (IOSConvertedProgress) async -> Void,
    renewed: @escaping @Sendable (IOSPlaybackTicket) async -> Void
  ) async throws -> Int64 {
    var ticket = initial
    var state = start
    func fetch(_ piece: String) async throws -> Data {
      var attempt = 0
      var waited: TimeInterval = 0
      var renewedOnce = false
      while true {
        try Task.checkCancellation()
        do {
          return try await api.downloadPiece(
            streamPath: ticket.streamPath, quality: state.quality, piece: piece, audio: state.audio)
        } catch let failure as IOSCoreError {
          if failure.statusCode == 401 || failure.statusCode == 404, !renewedOnce,
            failure.code != "segment_not_found"
          {
            ticket = try await api.createTicket(mediaID: mediaID, forDownload: true)
            await renewed(ticket)
            renewedOnce = true
            continue
          }
          guard
            let delay = IOSConvertedDownloadPlan.retryDelay(
              status: failure.statusCode, retryAfter: failure.retryAfter, attempt: attempt),
            waited + delay <= IOSConvertedDownloadPlan.longestWait
          else { throw failure }
          attempt += 1
          waited += delay
          try await Task.sleep(for: .seconds(delay))
        } catch let failure as URLError where failure.code != .cancelled {
          guard
            let delay = IOSConvertedDownloadPlan.retryDelay(
              status: nil, retryAfter: nil, attempt: attempt)
          else { throw failure }
          attempt += 1
          try await Task.sleep(for: .seconds(delay))
        }
      }
    }

    let count = IOSConvertedDownloadPlan.segmentCount(
      playlist: String(decoding: try await fetch("index.m3u8"), as: UTF8.self))
    guard count > 0 else { throw IOSCoreError.invalidResponse }
    if state.segmentCount != count { state.nextSegment = 0 }
    state.segmentCount = count
    try IOSConvertedDownloadPlan.prepare(
      partial, progress: &state, initData: try await fetch("init.mp4"))
    await saved(state)
    let handle = try FileHandle(forWritingTo: partial)
    defer { try? handle.close() }
    try handle.seekToEnd()
    for index in state.nextSegment..<count {
      let segment = try await fetch("\(index).m4s")
      try handle.write(contentsOf: segment)
      state.nextSegment = index + 1
      state.writtenBytes += Int64(segment.count)
      await saved(state)
    }
    try handle.synchronize()
    return state.writtenBytes
  }
}
