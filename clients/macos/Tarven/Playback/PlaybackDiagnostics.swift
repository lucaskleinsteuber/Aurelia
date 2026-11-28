import Foundation

enum PlaybackRecoveryCause: String, Codable, Sendable {
  case mediaUnavailable, mediaSourceUnavailable, connectionInterrupted, decoderError, stalled,
    prematureEnd
  case accessDenied, serverIdentityMismatch, invalidStream, preparationTimedOut
  case mediaFileUnavailable, mediaNotFound, mediaNotPlayable, unknownFailure, rateLimited

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
    case .preparationTimedOut: "Playback preparation timed out. Retrying…"
    case .mediaFileUnavailable: "The media file cannot be accessed safely. Check its permissions."
    case .mediaNotFound: "This media item is no longer available."
    case .mediaNotPlayable: "This media item cannot be played."
    case .unknownFailure: "Playback could not start. Choose Try Again after checking the server."
    case .rateLimited: "The server is busy with other streams. Waiting to retry…"
    }
  }

  static func classify(_ error: Error) -> Self {
    PlaybackFailureContext(error: error, phase: .ticketAuthorization).cause
  }
}

enum PlaybackDiagnosticPhase: String, Codable, Sendable {
  case ticketAuthorization, relayStartup, firstMovement, playback, ticketRenewal, streamTransport
}

/// Only fixed codes and bounded numbers may cross the diagnostic boundary.
/// Raw error descriptions, response bodies, headers, URLs and paths are excluded.
struct PlaybackFailureContext: LocalizedError, Equatable, Sendable {
  let cause: PlaybackRecoveryCause
  let phase: PlaybackDiagnosticPhase
  let httpStatus: Int?
  let urlErrorCode: Int?
  let problemCode: String?
  let bytesTransferred: Int64?
  let retryAfter: TimeInterval?
  let localReason: String?

  static let problemCodes: Set<String> = [
    "media_unavailable", "media_file_unavailable", "media_not_found", "media_not_playable",
    "invalid_session", "session_revoked", "access_denied", "playback_ticket_expired",
    "playback_ticket_not_found", "stream_limit", "stream_limit_reached", "too_many_streams",
  ]
  static let localReasons: Set<String> = [
    "readerClosed", "readerCancelled", "upstreamCancelled", "bufferLimit", "truncatedBody",
    "invalidResponse", "listenerFailure", "cancelled", "timeout", "transportFailure",
  ]

  init(
    cause: PlaybackRecoveryCause, phase: PlaybackDiagnosticPhase, httpStatus: Int? = nil,
    urlErrorCode: Int? = nil, problemCode: String? = nil, bytesTransferred: Int64? = nil,
    retryAfter: TimeInterval? = nil, localReason: String? = nil
  ) {
    self.cause = cause
    self.phase = phase
    self.httpStatus = httpStatus.flatMap { (100...599).contains($0) ? $0 : nil }
    self.urlErrorCode = urlErrorCode.flatMap { (-10_000...0).contains($0) ? $0 : nil }
    self.problemCode = problemCode.flatMap { Self.problemCodes.contains($0) ? $0 : nil }
    self.bytesTransferred = bytesTransferred.map { max(0, $0) }
    self.retryAfter = retryAfter.flatMap { $0.isFinite ? min(max(0, $0), 300) : nil }
    self.localReason = localReason.flatMap { Self.localReasons.contains($0) ? $0 : nil }
  }

  init(error: Error, phase: PlaybackDiagnosticPhase) {
    if let context = error as? Self {
      self = context
      return
    }
    if let timeout = error as? PlaybackOperationError,
      case .timedOut(let timeoutPhase) = timeout
    {
      self.init(cause: .preparationTimedOut, phase: timeoutPhase, localReason: "timeout")
      return
    }
    if let api = error as? APIClientError {
      let cause: PlaybackRecoveryCause
      if api.isAuthenticationFailure
        || ["invalid_session", "session_revoked", "access_denied"]
          .contains(api.problemCode ?? "")
      {
        cause = .accessDenied
      } else if api == .serverIdentityMismatch {
        cause = .serverIdentityMismatch
      } else {
        switch api.problemCode {
        case "media_unavailable": cause = .mediaUnavailable
        case "media_file_unavailable": cause = .mediaFileUnavailable
        case "media_not_found": cause = .mediaNotFound
        case "media_not_playable": cause = .mediaNotPlayable
        case "stream_limit", "stream_limit_reached", "too_many_streams": cause = .rateLimited
        default:
          if api.httpStatus == 429 {
            cause = .rateLimited
          } else if phase == .streamTransport, [404, 410].contains(api.httpStatus ?? 0) {
            cause = .mediaSourceUnavailable
          } else if api == .invalidResponse {
            cause = .invalidStream
          } else if api.isRetryableTransient {
            cause = .connectionInterrupted
          } else {
            cause = .unknownFailure
          }
        }
      }
      self.init(
        cause: cause, phase: phase, httpStatus: api.httpStatus,
        problemCode: api.problemCode, retryAfter: api.retryDelay)
      return
    }
    if let url = error as? URLError {
      let untrusted = [
        URLError.Code.serverCertificateUntrusted, .serverCertificateHasBadDate,
        .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
      ].contains(url.code)
      self.init(
        cause: untrusted
          ? .serverIdentityMismatch
          : (TicketRenewalPolicy.isTransient(url) ? .connectionInterrupted : .unknownFailure),
        phase: phase, urlErrorCode: url.errorCode,
        localReason: url.code == .cancelled ? "cancelled" : "transportFailure")
      return
    }
    self.init(cause: .unknownFailure, phase: phase)
  }

  var isRecoverable: Bool {
    switch cause {
    case .mediaUnavailable, .mediaSourceUnavailable, .connectionInterrupted, .decoderError,
      .stalled, .prematureEnd, .preparationTimedOut, .rateLimited:
      true
    default: false
    }
  }

  var errorDescription: String? { cause.message }
}

enum PlaybackOperationError: LocalizedError, Equatable {
  case timedOut(PlaybackDiagnosticPhase)

  var errorDescription: String? {
    switch self {
    case .timedOut(.relayStartup): "The local playback relay did not become ready in time."
    case .timedOut(.firstMovement): "Playback did not begin advancing in time."
    case .timedOut: "Playback authorization did not complete in time."
    }
  }
}

struct PlaybackDiagnosticEvent: Codable, Equatable, Sendable {
  enum Kind: String, Codable, Sendable {
    case started, prepared, recoveryStarted, recoveryAttempt, recovered, recoveryExhausted
    case stopped, ended, nextEpisode, progressPending, progressConflict, progressAccessDenied
    case progressStorageFailure, authorizationStopped, recoveryCancelled, operationTimedOut
    case failureObserved
  }
  let timestamp: Date
  let kind: Kind
  let cause: PlaybackRecoveryCause?
  let attempt: Int?
  let positionMilliseconds: Int64
  let durationMilliseconds: Int64
  var phase: PlaybackDiagnosticPhase? = nil
  var httpStatus: Int? = nil
  var urlErrorCode: Int? = nil
  var problemCode: String? = nil
  var bytesTransferred: Int64? = nil
  var retryAfter: TimeInterval? = nil
  var localReason: String? = nil
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
    attempt: Int? = nil, position: Int64, duration: Int64,
    phase: PlaybackDiagnosticPhase? = nil, httpStatus: Int? = nil, urlErrorCode: Int? = nil,
    problemCode: String? = nil, bytesTransferred: Int64? = nil, retryAfter: TimeInterval? = nil,
    localReason: String? = nil
  ) {
    let safe = PlaybackFailureContext(
      cause: cause ?? .unknownFailure, phase: phase ?? .playback, httpStatus: httpStatus,
      urlErrorCode: urlErrorCode, problemCode: problemCode, bytesTransferred: bytesTransferred,
      retryAfter: retryAfter, localReason: localReason)
    events.append(
      PlaybackDiagnosticEvent(
        timestamp: Date(), kind: kind, cause: cause, attempt: attempt,
        positionMilliseconds: max(0, position), durationMilliseconds: max(0, duration),
        phase: phase, httpStatus: safe.httpStatus, urlErrorCode: safe.urlErrorCode,
        problemCode: safe.problemCode, bytesTransferred: safe.bytesTransferred,
        retryAfter: safe.retryAfter, localReason: safe.localReason))
    if events.count > Self.capacity { events.removeFirst(events.count - Self.capacity) }
  }

  func export() throws -> Data {
    struct Export: Encodable {
      let formatVersion = 2
      let events: [PlaybackDiagnosticEvent]
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(Export(events: events))
  }
}
