import Foundation

enum PlaybackRecoveryCause: String, Codable, Sendable {
  case mediaUnavailable, mediaSourceUnavailable, connectionInterrupted, decoderError, stalled,
    prematureEnd
  case accessDenied, serverIdentityMismatch, invalidStream

  var message: String {
    switch self {
    case .mediaUnavailable: "The media drive is unavailable. Waiting to reconnect…"
    case .mediaSourceUnavailable:
      "The media source or playback ticket is unavailable. Reconnecting…"
    case .connectionInterrupted: "The server connection was interrupted. Reconnecting…"
    case .decoderError: "The video decoder stopped unexpectedly. Retrying playback…"
    case .stalled: "Playback is not advancing. Reconnecting…"
    case .prematureEnd: "The stream ended before the video finished. Reconnecting…"
    case .accessDenied: "Playback access was denied. Sign in again or check library access."
    case .serverIdentityMismatch: "The server identity could not be verified. Playback has stopped."
    case .invalidStream: "The server returned an invalid media stream."
    }
  }

  static func classify(_ error: Error) -> Self {
    if let api = error as? APIClientError {
      if api.problemCode == "media_unavailable" { return .mediaUnavailable }
      if api.isAuthenticationFailure { return .accessDenied }
      if api == .serverIdentityMismatch { return .serverIdentityMismatch }
      if api == .invalidResponse { return .invalidStream }
    }
    if let url = error as? URLError,
      [
        .serverCertificateUntrusted, .serverCertificateHasBadDate,
        .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
      ].contains(url.code)
    {
      return .serverIdentityMismatch
    }
    return .connectionInterrupted
  }
}

struct PlaybackDiagnosticEvent: Codable, Equatable, Sendable {
  enum Kind: String, Codable, Sendable {
    case started, prepared, recoveryStarted, recoveryAttempt, recovered, recoveryExhausted
    case stopped, ended, nextEpisode, progressPending, progressConflict, progressAccessDenied
    case progressStorageFailure, authorizationStopped, recoveryCancelled
  }
  let timestamp: Date
  let kind: Kind
  let cause: PlaybackRecoveryCause?
  let attempt: Int?
  let positionMilliseconds: Int64
  let durationMilliseconds: Int64
}

/// Closed schema prevents error descriptions, tokens, stream URLs, media paths
/// or titles from entering the diagnostic log. In-memory only, bounded to 200
/// events; export is an explicit user action rather than automatic telemetry.
@MainActor
final class PlaybackDiagnostics {
  static let capacity = 200
  private(set) var events: [PlaybackDiagnosticEvent] = []

  func record(
    _ kind: PlaybackDiagnosticEvent.Kind, cause: PlaybackRecoveryCause? = nil,
    attempt: Int? = nil, position: Int64, duration: Int64
  ) {
    events.append(
      PlaybackDiagnosticEvent(
        timestamp: Date(), kind: kind, cause: cause, attempt: attempt,
        positionMilliseconds: max(0, position), durationMilliseconds: max(0, duration)))
    if events.count > Self.capacity { events.removeFirst(events.count - Self.capacity) }
  }

  func export() throws -> Data {
    struct Export: Encodable {
      let formatVersion = 1
      let events: [PlaybackDiagnosticEvent]
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(Export(events: events))
  }
}
