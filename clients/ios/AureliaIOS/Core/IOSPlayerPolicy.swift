import Foundation

/// What the player does after its stream relay reports a failure.
enum IOSStreamFailureResponse: Equatable {
  case endSession(IOSCoreError)
  case fail(String, canRetry: Bool)
  case reconnect
}

enum IOSPlayerPolicy {
  static let progressInterval: TimeInterval = 15
  static let notAllowedMessage = "This title isn’t available for this profile."
  static let unavailableMessage =
    "Media file unavailable. Its drive may be disconnected, or the file was moved."

  /// The server's codes for a title whose file or drive cannot be read right now.
  static let unavailableCodes: Set<String> = [
    "media_not_found", "media_file_unavailable", "media_unavailable",
  ]

  static func unavailability(_ error: IOSCoreError) -> String? {
    guard unavailableCodes.contains(error.code ?? "") else { return nil }
    return error.serverMessage ?? unavailableMessage
  }

  /// A request the server refused without ending the session: the player says why and stays put.
  static func refusal(_ error: IOSCoreError) -> String? {
    guard error.statusCode == 403, !error.endsSession else { return nil }
    return error.serverMessage ?? notAllowedMessage
  }

  static func response(to failure: IOSStreamFailure) -> IOSStreamFailureResponse {
    switch failure {
    case .untrustedServer:
      return .endSession(.identityMismatch)
    case .server(let status, let code) where status == 401 || status == 403:
      let error = IOSCoreError.server(status: status, code: code, message: nil, retryAfter: nil)
      return error.endsSession ? .endSession(error) : .fail(notAllowedMessage, canRetry: false)
    case .server(let status, let code)
    where status == 404 || status == 410 || unavailableCodes.contains(code ?? ""):
      // A missing or offline file does not come back by reconnecting.
      return .fail(unavailableMessage, canRetry: true)
    case .server(429, _):
      return .fail("The server is busy. Try again in a moment.", canRetry: true)
    case .invalidResponse:
      return .fail("The server returned an invalid media stream.", canRetry: true)
    case .interrupted, .server:
      return .reconnect
    }
  }
  static let controlsDelay: TimeInterval = 4

  static func expiry(_ value: String) -> Date? { IOSServerDate.parse(value) }

  static func renewalDelay(expiresAt: Date, now: Date) -> TimeInterval {
    max(1, expiresAt.timeIntervalSince(now) - 60)
  }

  static func resumePosition(_ progress: IOSPlaybackProgress) -> Int64 {
    progress.isCompleted ? 0 : max(0, progress.positionMilliseconds)
  }

  static func seekPosition(current: Int64, offset: Int64, duration: Int64) -> Int64 {
    let (sum, overflow) = current.addingReportingOverflow(offset)
    let requested = overflow ? (offset > 0 ? Int64.max : 0) : max(0, sum)
    return duration > 0 ? min(requested, max(0, duration - 500)) : requested
  }

  // A decoder can report EOF for a truncated stream. Only an actual observed
  // clock near a known end can finish a title; loading failures never do.
  static func isNaturalCompletion(
    position: Int64, duration: Int64, observedPlayback: Bool, transportFailed: Bool
  ) -> Bool {
    guard observedPlayback, !transportFailed, duration > 0, position > 0 else { return false }
    let tolerance = max(1_000, min(5_000, duration / 100))
    return position >= duration - tolerance
  }

  static func mayHideControls(
    playing: Bool, menuOpen: Bool, interacting: Bool, loading: Bool, hasError: Bool
  ) -> Bool {
    playing && !menuOpen && !interacting && !loading && !hasError
  }

  /// "Ends at 21:43": when the title finishes if it plays on from `position` at `rate`.
  static func endTimeLabel(
    position: Int64, duration: Int64, rate: Double, now: Date, locale: Locale = .current,
    timeZone: TimeZone = .current
  ) -> String? {
    guard duration > 0, rate > 0 else { return nil }
    let remaining = Double(max(0, duration - position)) / 1_000 / rate
    var style = Date.FormatStyle(date: .omitted, time: .shortened)
    style.locale = locale
    style.timeZone = timeZone
    return "Ends at \(now.addingTimeInterval(remaining).formatted(style))"
  }

  /// The decoder opened at the resume position when its first clock lands near it.
  static func openedAtResume(clock: Int64, resume: Int64) -> Bool {
    abs(clock - resume) <= 5_000
  }

  /// How far one scrub press moves: the skip interval, larger while presses follow quickly.
  static func scrubStep(base: Int64, repeats: Int) -> Int64 {
    switch repeats {
    case ..<4: base
    case ..<10: base * 3
    default: base * 6
    }
  }

  /// "Up Next" appears in the last seconds of an episode-length title when the next episode
  /// will start on its own.
  static let upNextLead: Int64 = 20_000

  static func showsUpNext(
    position: Int64, duration: Int64, hasNext: Bool, autoplay: Bool, stopsAtEnd: Bool,
    dismissed: Bool
  ) -> Bool {
    guard hasNext, autoplay, !stopsAtEnd, !dismissed, duration >= 300_000, position > 0 else {
      return false
    }
    return duration - position <= upNextLead
  }

  static func upNextSeconds(position: Int64, duration: Int64) -> Int {
    Int((max(0, duration - position) + 999) / 1_000)
  }

  static func timeLabel(milliseconds: Int64) -> String {
    let seconds = max(0, milliseconds) / 1_000
    return seconds >= 3_600
      ? String(format: "%lld:%02lld:%02lld", seconds / 3_600, seconds / 60 % 60, seconds % 60)
      : String(format: "%lld:%02lld", seconds / 60, seconds % 60)
  }
}

struct IOSPlaybackRecoveryBudget: Sendable {
  private(set) var attempts = 0
  let maximumAttempts: Int

  init(maximumAttempts: Int = 2) { self.maximumAttempts = maximumAttempts }

  mutating func takeAttempt() -> TimeInterval? {
    guard attempts < maximumAttempts else { return nil }
    attempts += 1
    return attempts == 1 ? 1 : 3
  }
}

struct IOSRelayRequest: Equatable, Sendable {
  let method: String
  let subtitleIndex: Int?
  let range: String?
  let ifRange: String?

  static func parse(_ data: Data, secret: String) throws -> Self {
    guard data.count <= 32_768, let text = String(data: data, encoding: .utf8),
      text.hasSuffix("\r\n\r\n")
    else { throw IOSRelayRequestError.invalidRequest }
    let lines = text.components(separatedBy: "\r\n")
    let parts = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[2] == "HTTP/1.1",
      parts[0] == "GET" || parts[0] == "HEAD"
    else { throw IOSRelayRequestError.invalidRequest }

    let streamPrefix = "/stream/\(secret)"
    let subtitlePrefix = "/subtitles/\(secret)/"
    var subtitleIndex: Int?
    if parts[1] == Substring(streamPrefix) {
      subtitleIndex = nil
    } else if parts[1].hasPrefix(subtitlePrefix) {
      let suffix = parts[1].dropFirst(subtitlePrefix.count)
      guard digits(suffix), let idx = Int(suffix) else { throw IOSRelayRequestError.invalidRequest }
      subtitleIndex = idx
    } else {
      throw IOSRelayRequestError.invalidRequest
    }

    var headers: [String: String] = [:]
    for line in lines.dropFirst() where !line.isEmpty {
      guard let colon = line.firstIndex(of: ":") else { throw IOSRelayRequestError.invalidRequest }
      let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty, headers[name] == nil, !value.contains("\r"), !value.contains("\n")
      else { throw IOSRelayRequestError.invalidRequest }
      headers[name] = value
    }
    guard let host = headers["host"], validHost(host), headers["content-length"] == nil,
      headers["transfer-encoding"] == nil, headers["upgrade"] == nil,
      headers["range"].map(validRange) ?? true
    else { throw IOSRelayRequestError.invalidRequest }
    return Self(
      method: String(parts[0]), subtitleIndex: subtitleIndex, range: headers["range"],
      ifRange: headers["if-range"])
  }

  private static func digits(_ value: Substring) -> Bool {
    value.utf8.allSatisfy { (48...57).contains($0) }
  }

  private static func validHost(_ host: String) -> Bool {
    if host == "127.0.0.1" { return true }
    guard host.hasPrefix("127.0.0.1:") else { return false }
    let port = host.dropFirst("127.0.0.1:".count)
    return !port.isEmpty && digits(port) && UInt16(port).map { $0 > 0 } == true
  }

  private static func validRange(_ value: String) -> Bool {
    guard value.hasPrefix("bytes=") else { return false }
    let parts = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty || !parts[1].isEmpty,
      digits(parts[0]), digits(parts[1])
    else { return false }
    if parts[0].isEmpty { return UInt64(parts[1]).map { $0 > 0 } == true }
    guard let start = UInt64(parts[0]) else { return false }
    if parts[1].isEmpty { return true }
    return UInt64(parts[1]).map { start <= $0 } == true
  }
}

enum IOSRelayRequestError: Error { case invalidRequest }
