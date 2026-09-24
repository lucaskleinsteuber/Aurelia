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
    lock.withLock {
      connections[id] = connection
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
    guard let host = url.host else {
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
      expectedFingerprint: publicKeyFingerprint
    ) { [weak self] in
      self?.finishConnection(id)
    }
    let session = sessionFactory(delegate)
    lock.withLock {
      sessions[id] = session
    }
    let task = session.dataTask(with: request)
    delegate.task = task
    task.resume()
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
    resources.0?.finishTasksAndInvalidate()
    resources.1?.cancel()
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

  private static func productionSession(delegate: URLSessionDelegate) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 60 * 60
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
  private let completion: @Sendable () -> Void
  private let lock = NSLock()
  private var sentHeaders = false
  private var finished = false

  init(
    connection: NWConnection,
    allowedHost: String,
    expectedFingerprint: String,
    completion: @escaping @Sendable () -> Void
  ) {
    self.connection = connection
    self.allowedHost = allowedHost
    self.expectedFingerprint = expectedFingerprint
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
    guard let response = response as? HTTPURLResponse,
      [200, 206, 416].contains(response.statusCode)
    else {
      completionHandler(.cancel)
      sendGatewayFailure()
      return
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
    lock.withLock { sentHeaders = true }
    connection.send(
      content: Data(lines.joined(separator: "\r\n").utf8),
      completion: .contentProcessed { error in
        completionHandler(error == nil ? .allow : .cancel)
      })
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive data: Data
  ) {
    dataTask.suspend()
    connection.send(content: data, completion: .contentProcessed { error in
      if error == nil {
        dataTask.resume()
      } else {
        dataTask.cancel()
      }
    })
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    let hadHeaders = lock.withLock { sentHeaders }
    if !hadHeaders {
      sendGatewayFailure()
      return
    }
    finish()
  }

  private func sendGatewayFailure() {
    let shouldSend = lock.withLock { () -> Bool in
      guard !sentHeaders else { return false }
      sentHeaders = true
      return true
    }
    guard shouldSend else {
      finish()
      return
    }
    let response = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nCache-Control: private, no-store\r\nConnection: close\r\n\r\n"
    connection.send(
      content: Data(response.utf8),
      contentContext: .finalMessage,
      isComplete: true,
      completion: .contentProcessed { [weak self] _ in self?.finish() })
  }

  private func finish() {
    let shouldFinish = lock.withLock { () -> Bool in
      guard !finished else { return false }
      finished = true
      return true
    }
    guard shouldFinish else { return }
    connection.send(
      content: nil,
      contentContext: .finalMessage,
      isComplete: true,
      completion: .contentProcessed { [completion] _ in completion() })
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
