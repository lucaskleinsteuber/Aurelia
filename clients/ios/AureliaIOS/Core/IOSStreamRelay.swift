@preconcurrency import Foundation
@preconcurrency import Network
import Security

enum IOSStreamRelayError: LocalizedError, Equatable {
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

enum IOSStreamFailure: Equatable, Sendable {
  case interrupted
  case untrustedServer
  case invalidResponse
  case server(status: Int, code: String?)
}

final class IOSStreamRelay: @unchecked Sendable {
  typealias SessionFactory = @Sendable (URLSessionDelegate) -> URLSession

  private let queue = DispatchQueue(label: "com.lucas.aurelia.ios.stream-relay")
  private let lock = NSLock()
  private let secret: String
  private let publicKeyFingerprint: String
  private let authorizationToken: String?
  /// "preview" for timeline frames, which the server counts apart from playback streams.
  private let streamPurpose: String?
  private let sessionFactory: SessionFactory
  private var sourceURL: URL
  private var listener: NWListener?
  private var startContinuation: CheckedContinuation<URL, Error>?
  private var sessions: [UUID: IOSRelayPooledSession] = [:]
  /// Upstream sessions whose last transfer ended. A seek reuses one, so its
  /// already verified HTTP/2 connection carries the new range request instead of
  /// a fresh TCP and TLS handshake. Each session still runs one transfer at a time.
  private var idleSessions: [IOSRelayPooledSession] = []
  static let maximumIdleSessions = 2
  private var createdSessionCount = 0
  private var connections: [UUID: NWConnection] = [:]
  private var upstreamDelegates: [UUID: IOSRelayUpstreamDelegate] = [:]
  private var failureHandler: (@MainActor @Sendable (IOSStreamFailure) -> Void)?
  private var reportedFailure = false

  init(
    sourceURL: URL,
    publicKeyFingerprint: String,
    authorizationToken: String? = nil,
    streamPurpose: String? = nil,
    sessionFactory: @escaping SessionFactory = IOSStreamRelay.productionSession
  ) throws {
    self.sourceURL = sourceURL
    self.publicKeyFingerprint = publicKeyFingerprint
    self.authorizationToken = authorizationToken
    self.streamPurpose = streamPurpose
    self.sessionFactory = sessionFactory
    self.secret = try Self.makeSecret()
  }

  func start() async throws -> URL {
    try await withTaskCancellationHandler {
      try await startListener()
    } onCancel: {
      self.stop()
    }
  }

  func subtitleURL(index: Int) -> URL? {
    let port = lock.withLock { listener?.port?.rawValue }
    guard let port else { return nil }
    return URL(string: "http://127.0.0.1:\(port)/subtitles/\(secret)/\(index)")
  }

  private func startListener() async throws -> URL {
    try Task.checkCancellation()
    return try await withCheckedThrowingContinuation { continuation in
      lock.withLock {
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        guard listener == nil else {
          continuation.resume(throwing: IOSStreamRelayError.couldNotStart)
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
    _ handler: @escaping @MainActor @Sendable (IOSStreamFailure) -> Void
  ) {
    lock.withLock { failureHandler = handler }
  }

  /// Upstream sessions created so far; reuse keeps this below the request count.
  var upstreamSessionCount: Int { lock.withLock { createdSessionCount } }

  func stop() {
    let resources = lock.withLock {
      () -> (NWListener?, [URLSession], [NWConnection], [IOSRelayUpstreamDelegate]) in
      let resources = (
        listener, (Array(sessions.values) + idleSessions).map(\.session),
        Array(connections.values), Array(upstreamDelegates.values)
      )
      listener = nil
      sessions.removeAll()
      idleSessions.removeAll()
      connections.removeAll()
      upstreamDelegates.removeAll()
      if let continuation = startContinuation {
        startContinuation = nil
        continuation.resume(throwing: CancellationError())
      }
      return resources
    }
    // A delegate may be waiting for downstream capacity. Wake it directly;
    // invalidation callbacks cannot run until its serial delegate queue returns.
    for delegate in resources.3 { delegate.cancelForwarding() }
    resources.0?.cancel()
    for session in resources.1 { session.invalidateAndCancel() }
    for connection in resources.2 { connection.cancel() }
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
          URL(string: "http://127.0.0.1:\(port.rawValue)/stream/\(secret)")
        )
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
      guard listener != nil, connections.count < 8 else { return false }
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
    queue.asyncAfter(deadline: .now() + 10) { [weak self] in
      guard let self else { return }
      let incomplete = lock.withLock { connections[id] != nil && sessions[id] == nil }
      if incomplete { finishConnection(id) }
    }
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
          let request = try IOSRelayRequest.parse(requestData, secret: self.secret)
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
    _ relayRequest: IOSRelayRequest,
    connection: NWConnection,
    id: UUID
  ) {
    var url = lock.withLock { sourceURL }
    if let subIdx = relayRequest.subtitleIndex {
      let pathComponents = url.pathComponents
      if let streamIdx = pathComponents.firstIndex(of: "streams"),
        streamIdx + 1 < pathComponents.count
      {
        let ticket = pathComponents[streamIdx + 1]
        var comp = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comp?.path = "/api/v1/streams/\(ticket)/subtitles/\(subIdx)"
        if let subURL = comp?.url {
          url = subURL
        }
      }
    } else if let hlsPath = relayRequest.hlsPath {
      guard let resolved = IOSRelayRequest.hlsURL(hlsPath, below: url) else {
        reject(connection, id: id, status: 400, reason: "Bad Request")
        return
      }
      url = resolved
    }
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
    if let streamPurpose {
      request.setValue(streamPurpose, forHTTPHeaderField: "X-Aurelia-Stream-Purpose")
    }
    if let range = relayRequest.range {
      request.setValue(range, forHTTPHeaderField: "Range")
    }
    if let ifRange = relayRequest.ifRange {
      request.setValue(ifRange, forHTTPHeaderField: "If-Range")
    }

    let delegate = IOSRelayUpstreamDelegate(
      connection: connection,
      allowedHost: host,
      expectedFingerprint: publicKeyFingerprint,
      isHead: relayRequest.method == "HEAD",
      failure: { [weak self] failure in
        self?.reportFailure(failure, connectionID: id)
      },
      completion: { [weak self] in
        self?.finishConnection(id)
      }
    )
    let pooled =
      lock.withLock { () -> IOSRelayPooledSession? in
        guard let index = idleSessions.lastIndex(where: { $0.host == host }) else { return nil }
        return idleSessions.remove(at: index)
      }
      ?? {
        let dispatcher = IOSRelaySessionDispatcher()
        lock.withLock { createdSessionCount += 1 }
        return IOSRelayPooledSession(
          session: sessionFactory(dispatcher), dispatcher: dispatcher, host: host)
      }()
    let task = pooled.session.dataTask(with: request)
    delegate.task = task
    pooled.dispatcher.attach(delegate, task: task)
    let isActive = lock.withLock {
      guard listener != nil, connections[id] != nil else { return false }
      sessions[id] = pooled
      upstreamDelegates[id] = delegate
      return true
    }
    guard isActive else {
      delegate.cancelForwarding()
      pooled.dispatcher.detach()
      pooled.session.invalidateAndCancel()
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
    let response =
      "HTTP/1.1 \(status) \(reason)\r\nContent-Length: 0\r\nCache-Control: private, no-store\r\nConnection: close\r\n\r\n"
    connection.send(
      content: Data(response.utf8),
      contentContext: .finalMessage,
      isComplete: true,
      completion: .contentProcessed { [weak self] _ in
        self?.finishConnection(id)
      })
  }

  private func finishConnection(_ id: UUID) {
    let resources = lock.withLock {
      () -> (IOSRelayPooledSession?, NWConnection?, IOSRelayUpstreamDelegate?) in
      (
        sessions.removeValue(forKey: id), connections.removeValue(forKey: id),
        upstreamDelegates.removeValue(forKey: id)
      )
    }
    // Cancelling the task wakes a delegate waiting for downstream capacity and
    // resets only its HTTP/2 stream; late callbacks of that task are dropped.
    resources.2?.cancelForwarding()
    if let pooled = resources.0 {
      pooled.dispatcher.detach()
      let reused = lock.withLock { () -> Bool in
        guard listener != nil, idleSessions.count < Self.maximumIdleSessions else { return false }
        idleSessions.append(pooled)
        return true
      }
      if !reused { pooled.session.invalidateAndCancel() }
    }
    resources.1?.cancel()
  }

  private func reportFailure(_ failure: IOSStreamFailure, connectionID: UUID) {
    // A seek or player teardown can close a local connection while its upstream
    // cancellation callback is still pending. Those callbacks are not outages.
    let handler = lock.withLock { () -> (@MainActor @Sendable (IOSStreamFailure) -> Void)? in
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
      throw IOSStreamRelayError.couldNotStart
    }
    return Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
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

struct IOSRelayPooledSession {
  let session: URLSession
  let dispatcher: IOSRelaySessionDispatcher
  let host: String
}

/// The fixed delegate of one pooled upstream session. It forwards callbacks to the
/// transfer currently attached and drops late callbacks of earlier, cancelled tasks.
final class IOSRelaySessionDispatcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var target: IOSRelayUpstreamDelegate?
  private var taskIdentifier: Int?

  fileprivate func attach(_ delegate: IOSRelayUpstreamDelegate, task: URLSessionTask) {
    lock.withLock {
      target = delegate
      taskIdentifier = task.taskIdentifier
    }
  }

  func detach() {
    lock.withLock {
      target = nil
      taskIdentifier = nil
    }
  }

  private func current(for task: URLSessionTask?) -> IOSRelayUpstreamDelegate? {
    lock.withLock {
      guard let target, task == nil || task?.taskIdentifier == taskIdentifier else { return nil }
      return target
    }
  }

  func urlSession(
    _ session: URLSession,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler:
      @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    guard let target = current(for: nil) else {
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }
    target.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
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
    guard let target = current(for: dataTask) else {
      completionHandler(.cancel)
      return
    }
    target.urlSession(
      session, dataTask: dataTask, didReceive: response, completionHandler: completionHandler)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    current(for: dataTask)?.urlSession(session, dataTask: dataTask, didReceive: data)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
  ) {
    current(for: task)?.urlSession(session, task: task, didCompleteWithError: error)
  }
}

private final class IOSRelayUpstreamDelegate: NSObject, URLSessionDataDelegate,
  URLSessionTaskDelegate, @unchecked Sendable
{
  weak var task: URLSessionDataTask?

  private let connection: NWConnection
  private let allowedHost: String
  private let expectedFingerprint: String
  private let isHead: Bool
  private let failure: @Sendable (IOSStreamFailure) -> Void
  private let completion: @Sendable () -> Void
  private let forwardingQueue = DispatchQueue(label: "com.lucas.aurelia.ios.stream-forwarding")
  private let bufferWindow = IOSRelayBufferWindow(maximumBytes: 1_048_576)
  private static let maximumChunkBytes = 65_536
  private var sentHeaders = false
  private var finished = false
  private var expectedBodyLength: Int64?
  private var receivedBodyLength: Int64 = 0
  private var chunks: [Data] = []
  private var sendInFlight = false
  private var upstreamCompleted = false
  private var rejectedStatus: Int?
  private var problemBody = Data()
  private static let maximumProblemBytes = 16_384

  init(
    connection: NWConnection,
    allowedHost: String,
    expectedFingerprint: String,
    isHead: Bool,
    failure: @escaping @Sendable (IOSStreamFailure) -> Void,
    completion: @escaping @Sendable () -> Void
  ) {
    self.connection = connection
    self.allowedHost = allowedHost
    self.expectedFingerprint = expectedFingerprint
    self.isHead = isHead
    self.failure = failure
    self.completion = completion
  }

  func cancelForwarding() {
    bufferWindow.cancel()
    task?.cancel()
    forwardingQueue.async { self.closeLocally() }
  }

  func urlSession(
    _ session: URLSession,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler:
      @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      IOSServerAddress.trustHost(challenge.protectionSpace.host)
        == IOSServerAddress.trustHost(allowedHost),
      let trust = challenge.protectionSpace.serverTrust,
      let fingerprint = try? IOSServerIdentity.fingerprint(trust: trust),
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
        // Read only a bounded problem document; never forward error bodies,
        // URLs or server-provided descriptions to the local decoder/log.
        self.rejectedStatus = response.statusCode
        completionHandler(.allow)
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
    let isRejected = forwardingQueue.sync { rejectedStatus != nil }
    if isRejected {
      forwardingQueue.async {
        guard !self.finished else { return }
        guard data.count <= Self.maximumProblemBytes - self.problemBody.count else {
          self.finishRejectedResponse()
          return
        }
        self.problemBody.append(data)
      }
      return
    }
    // Foundation does not bound callback size, and callbacks already in flight
    // can arrive while suspending. Admit copied chunks through a bounded window
    // rather than rejecting valid data. Only this serial URLSession delegate
    // queue may wait; the forwarding queue and main actor never wait for space.
    dataTask.suspend()
    defer { dataTask.resume() }
    let accepted = forwardingQueue.sync {
      guard !self.finished else { return false }
      let (received, overflow) = self.receivedBodyLength.addingReportingOverflow(Int64(data.count))
      guard !overflow,
        self.expectedBodyLength.map({ received <= $0 }) ?? true
      else {
        self.fail(.invalidResponse)
        return false
      }
      self.receivedBodyLength = received
      return true
    }
    guard accepted else { return }
    var offset = 0
    while offset < data.count {
      let count = min(Self.maximumChunkBytes, data.count - offset)
      guard bufferWindow.reserve(count) else { return }
      // An explicit copy prevents a small Data slice from retaining the whole
      // Foundation callback. The original callback itself is framework-owned;
      // our queued and in-flight copies together remain at most one MiB.
      let chunk = data.withUnsafeBytes { bytes in
        Data(bytes: bytes.baseAddress!.advanced(by: offset), count: count)
      }
      forwardingQueue.async {
        guard !self.finished else {
          self.bufferWindow.release(chunk.count)
          return
        }
        self.chunks.append(chunk)
        self.forwardNextChunk()
      }
      offset += count
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    forwardingQueue.async {
      guard !self.finished else { return }
      if self.rejectedStatus != nil {
        self.finishRejectedResponse()
        return
      }
      if let error {
        let error = error as NSError
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
          self.closeLocally()
        } else if error.domain == NSURLErrorDomain
          && [
            NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
            NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
          ].contains(error.code)
        {
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
      bufferWindow.cancel()
      connection.send(
        content: nil,
        contentContext: .finalMessage,
        isComplete: true,
        completion: .contentProcessed { [completion] _ in completion() })
      return
    }
    let chunk = chunks.removeFirst()
    sendInFlight = true
    connection.send(
      content: chunk,
      completion: .contentProcessed { error in
        self.forwardingQueue.async {
          guard !self.finished else { return }
          self.sendInFlight = false
          self.bufferWindow.release(chunk.count)
          guard error == nil else {
            self.closeLocally()
            return
          }
          self.forwardNextChunk()
        }
      })
  }

  private func fail(_ reason: IOSStreamFailure) {
    guard !finished else { return }
    finished = true
    chunks.removeAll()
    bufferWindow.cancel()
    failure(reason)
    task?.cancel()
    guard !sentHeaders else {
      // Do not manufacture a successful EOF for truncated or failed transfers.
      completion()
      return
    }
    let response =
      "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nCache-Control: private, no-store\r\nConnection: close\r\n\r\n"
    connection.send(
      content: Data(response.utf8),
      contentContext: .finalMessage,
      isComplete: true,
      completion: .contentProcessed { [completion] _ in completion() })
  }

  private func finishRejectedResponse() {
    guard let rejectedStatus else { return }
    let code: String?
    if let document = try? JSONSerialization.jsonObject(with: problemBody) as? [String: Any] {
      code = document["code"] as? String
    } else {
      code = nil
    }
    problemBody.removeAll()
    fail(.server(status: rejectedStatus, code: code))
  }

  private func closeLocally() {
    guard !finished else { return }
    finished = true
    chunks.removeAll()
    bufferWindow.cancel()
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

/// Reservations include queued and in-flight copied chunks. Cancellation is
/// independent of URLSession's delegate queue so teardown can wake a blocked
/// producer even before Foundation delivers its cancellation callback.
final class IOSRelayBufferWindow: @unchecked Sendable {
  private let condition = NSCondition()
  private let maximumBytes: Int
  private var reservedBytes = 0
  private var cancelled = false
  private var waitingProducers = 0

  // Internal observation lets tests establish an actual blocked producer,
  // rather than assuming scheduling or a particular OS socket buffer size.
  var waitingProducerCount: Int {
    condition.lock()
    defer { condition.unlock() }
    return waitingProducers
  }

  init(maximumBytes: Int) {
    self.maximumBytes = maximumBytes
  }

  func reserve(_ count: Int) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    guard count >= 0, count <= maximumBytes else { return false }
    while !cancelled && count > maximumBytes - reservedBytes {
      waitingProducers += 1
      condition.wait()
      waitingProducers -= 1
    }
    guard !cancelled else { return false }
    reservedBytes += count
    return true
  }

  func release(_ count: Int) {
    condition.lock()
    defer { condition.unlock() }
    guard !cancelled else { return }
    reservedBytes -= count
    condition.broadcast()
  }

  func cancel() {
    condition.lock()
    cancelled = true
    reservedBytes = 0
    condition.broadcast()
    condition.unlock()
  }
}
