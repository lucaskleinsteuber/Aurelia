@preconcurrency import Foundation

/// Reads a title's sound track as plain PCM from the server, in chunks, checking the server's
/// pinned key like every other request. The transfer pauses while the speech recognizer is
/// behind, so at most a few megabytes wait in memory; nothing is written to disk.
final class SpeechAudioReader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  static let pauseAbove = 8 * 1024 * 1024
  static let resumeBelow = 2 * 1024 * 1024

  private let request: URLRequest
  private let fingerprint: String
  private let host: String
  private let lock = NSLock()
  private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
  private var task: URLSessionDataTask?
  private var session: URLSession?
  private var waiting = 0
  private var paused = false
  private var status = 0

  init(request: URLRequest, fingerprint: String) {
    self.request = request
    self.fingerprint = fingerprint
    host = request.url?.host ?? ""
  }

  /// The sound in chunks; reading ends with the track or with the stream's consumer.
  func chunks() -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { continuation in
      lock.withLock { self.continuation = continuation }
      let configuration = URLSessionConfiguration.ephemeral
      configuration.urlCache = nil
      configuration.httpCookieStorage = nil
      configuration.timeoutIntervalForRequest = 120
      configuration.timeoutIntervalForResource = 6 * 3600
      let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
      let task = session.dataTask(with: request)
      lock.withLock {
        self.session = session
        self.task = task
      }
      continuation.onTermination = { [weak self] _ in self?.stop() }
      task.resume()
    }
  }

  /// The consumer took `count` bytes: the transfer goes on once little is left waiting.
  func consumed(_ count: Int) {
    let resume = lock.withLock {
      waiting = max(0, waiting - count)
      guard paused, waiting < Self.resumeBelow else { return false }
      paused = false
      return true
    }
    if resume { task?.resume() }
  }

  func stop() {
    let (task, session) = lock.withLock { (self.task, self.session) }
    task?.cancel()
    session?.invalidateAndCancel()
  }

  func urlSession(
    _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) ->
      Void
  ) {
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      challenge.protectionSpace.host.caseInsensitiveCompare(host) == .orderedSame,
      let trust = challenge.protectionSpace.serverTrust,
      let presented = try? ServerPublicKeyFingerprint.calculate(from: trust),
      presented.caseInsensitiveCompare(fingerprint) == .orderedSame
    else {
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }
    completionHandler(.useCredential, URLCredential(trust: trust))
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    lock.withLock { status = code }
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    let (continuation, status, pause) = lock.withLock {
      waiting += data.count
      let pause = !paused && waiting > Self.pauseAbove
      if pause { paused = true }
      return (self.continuation, self.status, pause)
    }
    // An error answer is collected for its message instead of being read as sound.
    guard status == 200 else {
      lock.withLock { errorBody.append(data) }
      return
    }
    continuation?.yield(data)
    if pause { dataTask.suspend() }
  }

  private var errorBody = Data()

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    let (continuation, status, body) = lock.withLock { (self.continuation, self.status, errorBody) }
    if let error {
      continuation?.finish(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : error)
    } else if status != 200 {
      continuation?.finish(
        throwing: APIClient.responseError(status: status, retryAfter: nil, data: body))
    } else {
      continuation?.finish()
    }
    session.finishTasksAndInvalidate()
  }
}
