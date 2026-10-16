import Foundation

enum TVPlayerPolicy {
  static let progressInterval: TimeInterval = 15
  static let controlsDelay: TimeInterval = 4

  static func expiry(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }

  static func renewalDelay(expiresAt: Date, now: Date) -> TimeInterval {
    max(1, expiresAt.timeIntervalSince(now) - 60)
  }

  static func resumePosition(_ progress: TVPlaybackProgress) -> Int64 {
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

  static func timeLabel(milliseconds: Int64) -> String {
    let seconds = max(0, milliseconds) / 1_000
    return seconds >= 3_600
      ? String(format: "%lld:%02lld:%02lld", seconds / 3_600, seconds / 60 % 60, seconds % 60)
      : String(format: "%lld:%02lld", seconds / 60, seconds % 60)
  }
}

struct TVPlaybackRecoveryBudget: Sendable {
  private(set) var attempts = 0
  let maximumAttempts: Int

  init(maximumAttempts: Int = 2) { self.maximumAttempts = maximumAttempts }

  mutating func takeAttempt() -> TimeInterval? {
    guard attempts < maximumAttempts else { return nil }
    attempts += 1
    return attempts == 1 ? 1 : 3
  }
}

struct TVRelayRequest: Equatable, Sendable {
  let method: String
  let range: String?
  let ifRange: String?

  static func parse(_ data: Data, secret: String) throws -> Self {
    guard data.count <= 32_768, let text = String(data: data, encoding: .utf8),
      text.hasSuffix("\r\n\r\n")
    else { throw TVRelayRequestError.invalidRequest }
    let lines = text.components(separatedBy: "\r\n")
    let parts = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[2] == "HTTP/1.1",
      parts[0] == "GET" || parts[0] == "HEAD", parts[1] == Substring("/stream/\(secret)")
    else { throw TVRelayRequestError.invalidRequest }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() where !line.isEmpty {
      guard let colon = line.firstIndex(of: ":") else { throw TVRelayRequestError.invalidRequest }
      let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty, headers[name] == nil, !value.contains("\r"), !value.contains("\n")
      else { throw TVRelayRequestError.invalidRequest }
      headers[name] = value
    }
    guard let host = headers["host"], validHost(host), headers["content-length"] == nil,
      headers["transfer-encoding"] == nil, headers["upgrade"] == nil,
      headers["range"].map(validRange) ?? true
    else { throw TVRelayRequestError.invalidRequest }
    return Self(method: String(parts[0]), range: headers["range"], ifRange: headers["if-range"])
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

enum TVRelayRequestError: Error { case invalidRequest }
