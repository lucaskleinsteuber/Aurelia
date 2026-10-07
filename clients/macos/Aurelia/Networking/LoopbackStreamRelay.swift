@preconcurrency import Foundation
@preconcurrency import Network
import Security

enum StreamRelayError: LocalizedError, Equatable {
  case couldNotStart
  case invalidRequest
  case unavailable

  var errorDescription: String? {
    switch self {
    case .couldNotStart:
      "The secure local playback relay could not start."
    case .invalidRequest:
      "The local playback request was invalid."
    case .unavailable:
      "The media stream is unavailable."
    }
  }
}

struct RelayRequest: Equatable, Sendable {
  let method: String
  let range: String?
  let ifRange: String?
}

enum PlaybackStreamFailure: Equatable, Sendable {
  case interrupted
  case unavailable
  case authorizationDenied
  case untrustedServer
  case invalidResponse
}

final class LoopbackStreamRelay: @unchecked Sendable {
  typealias SessionFactory = @Sendable (URLSessionDelegate) -> URLSession

  private let queue = DispatchQueue(label: "com.lucas.aurelia.media.stream-relay")
  private let lock = NSLock()
  private let secret: String
  private let publicKeyFingerprint: String
  private let authorizationToken: String?
  private let sessionFactory: SessionFactory
  private var sourceURL: URL
  private var listener: NWListener?
  private var startContinuation: CheckedContinuation<URL, Error>?
  private var sessions: [UUID: URLSession] = [:]
  private var connections: [UUID: NWConnection] = [:]
  private var failureHandler: (@MainActor @Sendable (PlaybackStreamFailure) -> Void)?
  private var reportedFailure = false

  init(
    sourceURL: URL,
    publicKeyFingerprint: String,
    authorizationToken: String? = nil,
    sessionFactory: @escaping SessionFactory = LoopbackStreamRelay.productionSession
  ) throws {
    self.sourceURL = sourceURL
    self.publicKeyFingerprint = publicKeyFingerprint
    self.authorizationToken = authorizationToken
    self.sessionFactory = sessionFactory
    self.secret = try Self.makeSecret()
  }

  func start() async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      lock.withLock {
        guard listener == nil else {
          continuation.resume(throwing: StreamRelayError.couldNotStart)
          return
        }

        do {
          let parameters = NWParameters.tcp
          parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: .any)
          let created = try NWListener(using: parameters)
          listener = created
          startContinuation = continuation
          created.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
          }
          created.stateUpdateHandler = { [weak self] state in
            self?.listenerChanged(state)
          }
          created.start(queue: queue)
        } catch {
          listener = nil
          startContinuation = nil
          continuation.resume(throwing: error)
        }
      }
    }
  }

  func updateSourceURL(_ url: URL) {
    lock.withLock {
      sourceURL = url
    }
  }

  func setFailureHandler(
    _ handler: @escaping @MainActor @Sendable (PlaybackStreamFailure) -> Void
  ) {
    lock.withLock { failureHandler = handler }
  }

  func stop() {
    let resources = lock.withLock { () -> (NWListener?, [URLSession], [NWConnection]) in
      let resources = (listener, Array(sessions.values), Array(connections.values))
      listener = nil
      sessions.removeAll()
      connections.removeAll()
      if let continuation = startContinuation {
        startContinuation = nil
        continuation.resume(throwing: CancellationError())
      }
      return resources
    }
    resources.0?.cancel()
    resources.1.forEach { $0.invalidateAndCancel() }
    resources.2.forEach { $0.cancel() }
  }

  static func parseRequest(_ data: Data, secret: String) throws -> RelayRequest {
    guard data.count <= 32_768,
      let text = String(data: data, encoding: .utf8),
      text.hasSuffix("\r\n\r\n")
    else {
      throw StreamRelayError.invalidRequest
    }

    let lines = text.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else {
      throw StreamRelayError.invalidRequest
    }
    let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
    guard requestParts.count == 3,
      requestParts[2] == "HTTP/1.1",
      requestParts[0] == "GET" || requestParts[0] == "HEAD",
      requestParts[1] == Substring("/stream/\(secret)")
    else {
      throw StreamRelayError.invalidRequest
    }

    var headers: [String: String] = [:]
    for line in lines.dropFirst() where !line.isEmpty {
      guard let separator = line.firstIndex(of: ":") else {
        throw StreamRelayError.invalidRequest
      }
      let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
      let value = line[line.index(after: separator)...]
        .trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty,
        headers[name] == nil,
        !value.contains("\r"),
        !value.contains("\n")
      else {
        throw StreamRelayError.invalidRequest
      }
      headers[name] = value
    }

    guard let host = headers["host"]?.lowercased(),
      isValidLoopbackHost(host),
      headers["content-length"] == nil,
      headers["transfer-encoding"] == nil
    else {
      throw StreamRelayError.invalidRequest
    }

    if let range = headers["range"], !isValidRange(range) {
      throw StreamRelayError.invalidRequest
    }

    return RelayRequest(
      method: String(requestParts[0]),
      range: headers["range"],
      ifRange: headers["if-range"])
  }

  private func listenerChanged(_ state: NWListener.State) {
    switch state {
    case .ready:
      let result = lock.withLock { () -> (CheckedContinuation<URL, Error>?, URL?) in
        guard let listener, let port = listener.port else { return (nil, nil) }
        let continuation = startContinuation
        startContinuation = nil
        return (
          continuation,
          URL(string: "http://127.0.0.1:\(port.rawValue)/stream/\(secret)"))
      }
      if let continuation = result.0, let url = result.1 {
        continuation.resume(returning: url)
      }
    case .failed(let error):
      let continuation = lock.withLock { () -> CheckedContinuation<URL, Error>? in
        let continuation = startContinuation
        startContinuation = nil
        listener = nil
        return continuation
      }
      continuation?.resume(throwing: error)
    case .cancelled:
      break
    default:
      break
    }
  }

  private func accept(_ connection: NWConnection) {
    let id = UUID()
    let accepted = lock.withLock {
      guard listener != nil else { return false }
      connections[id] = connection
      return true
    }
    guard accepted else {
      connection.cancel()
      return
    }
    connection.stateUpdateHandler = { [weak self] state in
      if case .failed = state {
        self?.finishConnection(id)
      } else if case .cancelled = state {
        self?.finishConnection(id)
      }
    }
    connection.start(queue: queue)
    receiveRequest(on: connection, id: id, accumulated: Data())
  }

  private func receiveRequest(on connection: NWConnection, id: UUID, accumulated: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) {
      [weak self] data, _, isComplete, error in
      guard let self else { return }
      if error != nil {
        self.finishConnection(id)
        return
      }

      var requestData = accumulated
      if let data {
        requestData.append(data)
      }
      if let range = requestData.range(of: Data("\r\n\r\n".utf8)) {
        guard range.upperBound == requestData.endIndex else {
          self.reject(connection, id: id, status: 400, reason: "Bad Request")
          return
        }
        do {
          let request = try Self.parseRequest(requestData, secret: self.secret)
          self.beginUpstream(request, connection: connection, id: id)
        } catch {
          self.reject(connection, id: id, status: 400, reason: "Bad Request")
        }
      } else if requestData.count >= 32_768 || isComplete {
        self.reject(connection, id: id, status: 431, reason: "Request Header Fields Too Large")
      } else {
        self.receiveRequest(on: connection, id: id, accumulated: requestData)
      }
    }
  }

  private func beginUpstream(
    _ relayRequest: RelayRequest,
    connection: NWConnection,
    id: UUID
  ) {
    let url = lock.withLock { sourceURL }
    guard url.scheme?.lowercased() == "https", let host = url.host else {
      reportFailure(.invalidResponse, connectionID: id)
      reject(connection, id: id, status: 502, reason: "Bad Gateway")
      return
    }

    var request = URLRequest(url: url)
    request.httpMethod = relayRequest.method
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    if let authorizationToken {
      request.setValue("Bearer \(authorizationToken)", forHTTPHeaderField: "Authorization")
    }
    if let range = relayRequest.range {
      request.setValue(range, forHTTPHeaderField: "Range")
    }
    if let ifRange = relayRequest.ifRange {
      request.setValue(ifRange, forHTTPHeaderField: "If-Range")
    }

    let delegate = RelayUpstreamDelegate(
      connection: connection,
      allowedHost: host,
      expectedFingerprint: publicKeyFingerprint,
      isHead: relayRequest.method == "HEAD",
      failure: { [weak self] failure in
        self?.reportFailure(failure, connectionID: id)
      }
    ) { [weak self] in
      self?.finishConnection(id)
    }
    let session = sessionFactory(delegate)
    let task = session.dataTask(with: request)
    delegate.task = task
    let isActive = lock.withLock {
      guard listener != nil, connections[id] != nil else { return false }
      sessions[id] = session
      return true
    }
    guard isActive else {
      session.invalidateAndCancel()
      connection.cancel()
      return
    }
    task.resume()
    // A canceled seek may send FIN without changing NWConnection.state. Watch
    // the read side as well, so a stalled upstream is canceled immediately.
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1) {
      [weak self] data, _, isComplete, error in
      if isComplete || error != nil || data?.isEmpty == false {
        self?.finishConnection(id)
      }
    }
  }

  private func reject(
    _ connection: NWConnection,
    id: UUID,
    status: Int,
    reason: String
  ) {
    let response = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: 0\r\nCache-Control: private, no-store\r\nConnection: close\r\n\r\n"
    connection.send(
      content: Data(response.utf8),
      contentContext: .finalMessage,
      isComplete: true,
      completion: .contentProcessed { [weak self] _ in
        self?.finishConnection(id)
      })
  }

  private func finishConnection(_ id: UUID) {
    let resources = lock.withLock { () -> (URLSession?, NWConnection?) in
      (sessions.removeValue(forKey: id), connections.removeValue(forKey: id))
    }
    resources.0?.invalidateAndCancel()
    resources.1?.cancel()
  }

  private func reportFailure(_ failure: PlaybackStreamFailure, connectionID: UUID) {
    // A seek or player teardown can close a local connection while its upstream
    // cancellation callback is still pending. Those callbacks are not outages.
    let handler = lock.withLock { () -> (@MainActor @Sendable (PlaybackStreamFailure) -> Void)? in
      guard connections[connectionID] != nil, listener != nil, !reportedFailure,
        let failureHandler
      else { return nil }
      reportedFailure = true
      return failureHandler
    }
    guard let handler else { return }
    Task { @MainActor in handler(failure) }
  }

  private static func makeSecret() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw StreamRelayError.couldNotStart
    }
    return Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func isValidRange(_ value: String) -> Bool {
    guard value.hasPrefix("bytes="),
      !value.contains(","),
      !value.contains(" ")
    else { return false }
    let specification = value.dropFirst("bytes=".count)
    let parts = specification.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 2,
      !parts[0].isEmpty || !parts[1].isEmpty,
      parts[0].allSatisfy(\.isNumber),
      parts[1].allSatisfy(\.isNumber)
    else { return false }
    if parts[0].isEmpty {
      return UInt64(parts[1]) != nil
    }
    guard let start = UInt64(parts[0]) else { return false }
    if parts[1].isEmpty { return true }
    guard let end = UInt64(parts[1]) else { return false }
    return start <= end
  }

  private static func isValidLoopbackHost(_ value: String) -> Bool {
    if value == "127.0.0.1" { return true }
    guard value.hasPrefix("127.0.0.1:") else { return false }
    let port = value.dropFirst("127.0.0.1:".count)
    return !port.isEmpty && port.allSatisfy(\.isNumber) && UInt16(port) != nil
  }

  static func productionSession(delegate: URLSessionDelegate) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.timeoutIntervalForRequest = 30
    // This is the lifetime of the entire transfer, not its inactivity limit.
    // A decoder's backpressure must not cut a healthy long movie at one hour.
    configuration.timeoutIntervalForResource = 12 * 60 * 60
    return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
  }
}

private final class RelayUpstreamDelegate: NSObject, URLSessionDataDelegate,
  URLSessionTaskDelegate, @unchecked Sendable
{
  weak var task: URLSessionDataTask?

  private let connection: NWConnection
  private let allowedHost: String
  private let expectedFingerprint: String
  private let isHead: Bool
  private let failure: @Sendable (PlaybackStreamFailure) -> Void
  private let completion: @Sendable () -> Void
  private let forwardingQueue = DispatchQueue(label: "com.lucas.aurelia.media.stream-forwarding")
  private let bufferLock = NSLock()
  private static let maximumBufferedBytes = 1_048_576
  private var reservedBytes = 0
  private var sentHeaders = false
  private var finished = false
  private var expectedBodyLength: Int64?
  private var receivedBodyLength: Int64 = 0
  private var chunks: [Data] = []
  private var sendInFlight = false
  private var upstreamCompleted = false

  init(
    connection: NWConnection,
    allowedHost: String,
    expectedFingerprint: String,
    isHead: Bool,
    failure: @escaping @Sendable (PlaybackStreamFailure) -> Void,
    completion: @escaping @Sendable () -> Void
  ) {
    self.connection = connection
    self.allowedHost = allowedHost
    self.expectedFingerprint = expectedFingerprint
    self.isHead = isHead
    self.failure = failure
    self.completion = completion
  }

  func urlSession(
    _ session: URLSession,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler:
      @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      challenge.protectionSpace.host.caseInsensitiveCompare(allowedHost) == .orderedSame,
      let trust = challenge.protectionSpace.serverTrust,
      let fingerprint = try? ServerPublicKeyFingerprint.calculate(from: trust),
      fingerprint.caseInsensitiveCompare(expectedFingerprint) == .orderedSame
    else {
      forwardingQueue.async { self.fail(.untrustedServer) }
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }
    completionHandler(.useCredential, URLCredential(trust: trust))
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    forwardingQueue.async {
      guard !self.finished else {
        completionHandler(.cancel)
        return
      }
      guard let response = response as? HTTPURLResponse else {
        completionHandler(.cancel)
        self.fail(.invalidResponse)
        return
      }
      guard [200, 206, 416].contains(response.statusCode) else {
        completionHandler(.cancel)
        switch response.statusCode {
        case 401, 403: self.fail(.authorizationDenied)
        case 404, 410, 503: self.fail(.unavailable)
        case 408, 429, 500, 502, 504: self.fail(.interrupted)
        default: self.fail(.invalidResponse)
        }
        return
      }
      if let length = response.value(forHTTPHeaderField: "Content-Length") {
        guard let parsed = Int64(length), parsed >= 0 else {
          completionHandler(.cancel)
          self.fail(.invalidResponse)
          return
        }
        self.expectedBodyLength = self.isHead ? 0 : parsed
      } else if self.isHead {
        self.expectedBodyLength = 0
      }

      var lines = [
        "HTTP/1.1 \(response.statusCode) \(Self.reason(response.statusCode))",
        "Cache-Control: private, no-store",
        "X-Content-Type-Options: nosniff",
        "Connection: close",
      ]
      for header in [
        "Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "ETag",
        "Last-Modified",
      ] {
        if let value = response.value(forHTTPHeaderField: header),
          !value.contains("\r"), !value.contains("\n")
        {
          lines.append("\(header): \(value)")
        }
      }
      lines.append("")
      lines.append("")
      self.sentHeaders = true
      self.connection.send(
        content: Data(lines.joined(separator: "\r\n").utf8),
        completion: .contentProcessed { error in
          completionHandler(error == nil ? .allow : .cancel)
          if error != nil {
            self.forwardingQueue.async { self.closeLocally() }
          }
        })
    }
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive data: Data
  ) {
    // Pause before enqueueing: otherwise a fast server can read the whole video
    // while the local decoder consumes it slowly. Only queued, bounded transfer
    // chunks are retained; nothing is cached or written to disk.
    dataTask.suspend()
    let accepted = bufferLock.withLock {
      guard data.count <= Self.maximumBufferedBytes - reservedBytes else { return false }
      reservedBytes += data.count
      return true
    }
    guard accepted else {
      dataTask.cancel()
      forwardingQueue.async { self.fail(.interrupted) }
      return
    }
    forwardingQueue.async {
      guard !self.finished else {
        dataTask.cancel()
        return
      }
      let (received, overflow) = self.receivedBodyLength.addingReportingOverflow(Int64(data.count))
      guard !overflow,
        self.expectedBodyLength.map({ received <= $0 }) ?? true
      else {
        self.fail(.invalidResponse)
        return
      }
      self.receivedBodyLength = received
      self.chunks.append(data)
      self.forwardNextChunk()
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    forwardingQueue.async {
      guard !self.finished else { return }
      if let error {
        let error = error as NSError
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
          self.closeLocally()
        } else if error.domain == NSURLErrorDomain && [
          NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
          NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
        ].contains(error.code) {
          self.fail(.untrustedServer)
        } else {
          self.fail(.interrupted)
        }
        return
      }
      guard self.sentHeaders else {
        self.fail(.invalidResponse)
        return
      }
      self.upstreamCompleted = true
      self.forwardNextChunk()
    }
  }

  private func forwardNextChunk() {
    guard !finished, !sendInFlight else { return }
    guard !chunks.isEmpty else {
      guard upstreamCompleted else { return }
      guard expectedBodyLength.map({ $0 == receivedBodyLength }) ?? true else {
        fail(.interrupted)
        return
      }
      finished = true
      connection.send(
        content: nil,
        contentContext: .finalMessage,
        isComplete: true,
        completion: .contentProcessed { [completion] _ in completion() })
      return
    }
    let chunk = chunks.removeFirst()
    sendInFlight = true
    connection.send(content: chunk, completion: .contentProcessed { error in
      self.forwardingQueue.async {
        guard !self.finished else { return }
        self.sendInFlight = false
        self.bufferLock.withLock { self.reservedBytes -= chunk.count }
        guard error == nil else {
          self.closeLocally()
          return
        }
        self.task?.resume()
        self.forwardNextChunk()
      }
    })
  }

  private func fail(_ reason: PlaybackStreamFailure) {
    guard !finished else { return }
    finished = true
    chunks.removeAll()
    bufferLock.withLock { reservedBytes = 0 }
    failure(reason)
    task?.cancel()
    guard !sentHeaders else {
      // Do not manufacture a successful EOF for truncated or failed transfers.
      completion()
      return
    }
    let response = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nCache-Control: private, no-store\r\nConnection: close\r\n\r\n"
    connection.send(
      content: Data(response.utf8),
      contentContext: .finalMessage,
      isComplete: true,
      completion: .contentProcessed { [completion] _ in completion() })
  }

  private func closeLocally() {
    guard !finished else { return }
    finished = true
    chunks.removeAll()
    bufferLock.withLock { reservedBytes = 0 }
    task?.cancel()
    completion()
  }

  private static func reason(_ status: Int) -> String {
    switch status {
    case 200: "OK"
    case 206: "Partial Content"
    case 416: "Range Not Satisfiable"
    default: "Bad Gateway"
    }
  }
}
