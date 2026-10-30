import Foundation
import Network
import Security

public enum IOSStreamRelayError: LocalizedError, Equatable {
  case couldNotStart
  case invalidRequest
  case unavailable

  public var errorDescription: String? {
    switch self {
    case .couldNotStart: return "The secure playback relay could not start."
    case .invalidRequest: return "The local playback request was invalid."
    case .unavailable: return "The media stream is unavailable."
    }
  }
}

public final class IOSStreamRelay: @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.lucas.aurelia.ios.stream-relay")
  private let lock = NSLock()
  private let secret: String
  private let publicKeyFingerprint: String
  private let authorizationToken: String?
  private var sourceURL: URL
  private var listener: NWListener?
  private var startContinuation: CheckedContinuation<URL, Error>?
  private var connections: [UUID: NWConnection] = [:]

  public init(
    sourceURL: URL,
    publicKeyFingerprint: String,
    authorizationToken: String? = nil
  ) {
    self.sourceURL = sourceURL
    self.publicKeyFingerprint = publicKeyFingerprint
    self.authorizationToken = authorizationToken
    self.secret = UUID().uuidString.lowercased()
  }

  public func start() async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { [weak self] in
        guard let self else {
          continuation.resume(throwing: IOSStreamRelayError.couldNotStart)
          return
        }
        do {
          let parameters = NWParameters.tcp
          parameters.allowLocalEndpointReuse = true
          let listener = try NWListener(using: parameters, on: .any)
          self.listener = listener
          self.startContinuation = continuation

          listener.stateUpdateHandler = { [weak self] state in
            self?.handleState(state)
          }
          listener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
          }
          listener.start(queue: self.queue)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  public func stop() {
    queue.async {
      self.listener?.cancel()
      self.listener = nil
      for (_, conn) in self.connections {
        conn.cancel()
      }
      self.connections.removeAll()
    }
  }

  public func subtitleURL(for index: Int) -> URL? {
    guard let port = listener?.port?.rawValue else { return nil }
    return URL(string: "http://127.0.0.1:\(port)/subtitles/\(secret)/\(index)")
  }

  private func handleState(_ state: NWListener.State) {
    switch state {
    case .ready:
      if let port = listener?.port?.rawValue {
        let localURL = URL(string: "http://127.0.0.1:\(port)/media/\(secret)")!
        startContinuation?.resume(returning: localURL)
        startContinuation = nil
      }
    case .failed(let error):
      startContinuation?.resume(throwing: error)
      startContinuation = nil
    default:
      break
    }
  }

  private func handleNewConnection(_ connection: NWConnection) {
    let id = UUID()
    lock.lock()
    connections[id] = connection
    lock.unlock()

    connection.stateUpdateHandler = { [weak self] state in
      if case .cancelled = state {
        self?.lock.lock()
        self?.connections.removeValue(forKey: id)
        self?.lock.unlock()
      }
    }

    connection.start(queue: queue)
    readHTTPHeader(connection: connection, id: id)
  }

  private func readHTTPHeader(connection: NWConnection, id: UUID) {
    connection.receive(minimumIncompleteLength: 4, maximumLength: 4096) {
      [weak self] content, _, isComplete, error in
      guard let self, let data = content, error == nil else {
        connection.cancel()
        return
      }

      guard let headerString = String(data: data, encoding: .utf8),
        let firstLine = headerString.components(separatedBy: "\r\n").first
      else {
        connection.cancel()
        return
      }

      let parts = firstLine.split(separator: " ")
      guard parts.count >= 2 else {
        connection.cancel()
        return
      }

      let path = String(parts[1])
      if path.hasPrefix("/media/\(self.secret)") {
        self.proxyMediaRequest(connection: connection, requestHeaders: headerString)
      } else if path.hasPrefix("/subtitles/\(self.secret)/") {
        let indexString = path.replacingOccurrences(of: "/subtitles/\(self.secret)/", with: "")
        if let index = Int(indexString) {
          self.proxySubtitleRequest(connection: connection, index: index)
        } else {
          connection.cancel()
        }
      } else {
        connection.cancel()
      }
    }
  }

  private func proxyMediaRequest(connection: NWConnection, requestHeaders: String) {
    var upstreamRequest = URLRequest(url: sourceURL)
    upstreamRequest.httpMethod = "GET"
    if let authorizationToken {
      upstreamRequest.setValue("Bearer \(authorizationToken)", forHTTPHeaderField: "Authorization")
    }

    // Forward Range header if present
    for line in requestHeaders.components(separatedBy: "\r\n") {
      if line.lowercased().hasPrefix("range:") {
        let parts = line.split(separator: ":", maxSplits: 1)
        if parts.count == 2 {
          upstreamRequest.setValue(
            parts[1].trimmingCharacters(in: .whitespaces), forHTTPHeaderField: "Range")
        }
      }
    }

    let delegate = IOSTLSTrustDelegate(
      mode: .pinned(publicKeyFingerprint), allowedHost: sourceURL.host ?? "")
    let config = URLSessionConfiguration.ephemeral
    let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

    let task = session.dataTask(with: upstreamRequest) { [weak connection] data, response, error in
      defer { session.invalidateAndCancel() }
      guard let connection, let http = response as? HTTPURLResponse, let data, error == nil else {
        connection?.cancel()
        return
      }

      var header = "HTTP/1.1 \(http.statusCode) OK\r\n"
      for (k, v) in http.allHeaderFields {
        if let key = k as? String, let val = v as? String {
          header += "\(key): \(val)\r\n"
        }
      }
      header += "\r\n"

      if let headerData = header.data(using: .utf8) {
        connection.send(content: headerData, completion: .contentProcessed({ _ in }))
        connection.send(
          content: data, isComplete: true,
          completion: .contentProcessed({ _ in
            connection.cancel()
          }))
      }
    }
    task.resume()
  }

  private func proxySubtitleRequest(connection: NWConnection, index: Int) {
    guard let subtitleURL = URL(string: "\(sourceURL.absoluteString)/subtitles/\(index)") else {
      connection.cancel()
      return
    }

    var upstreamRequest = URLRequest(url: subtitleURL)
    upstreamRequest.httpMethod = "GET"
    if let authorizationToken {
      upstreamRequest.setValue("Bearer \(authorizationToken)", forHTTPHeaderField: "Authorization")
    }

    let delegate = IOSTLSTrustDelegate(
      mode: .pinned(publicKeyFingerprint), allowedHost: sourceURL.host ?? "")
    let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)

    let task = session.dataTask(with: upstreamRequest) { [weak connection] data, response, error in
      defer { session.invalidateAndCancel() }
      guard let connection, let http = response as? HTTPURLResponse, let data, error == nil else {
        connection?.cancel()
        return
      }

      var header = "HTTP/1.1 \(http.statusCode) OK\r\n"
      header += "Content-Type: text/vtt; charset=utf-8\r\n"
      header += "Content-Length: \(data.count)\r\n\r\n"

      if let headerData = header.data(using: .utf8) {
        connection.send(content: headerData, completion: .contentProcessed({ _ in }))
        connection.send(
          content: data, isComplete: true,
          completion: .contentProcessed({ _ in
            connection.cancel()
          }))
      }
    }
    task.resume()
  }
}
