import Foundation
import XCTest

@testable import Aurelia

final class LoopbackStreamRelayTests: XCTestCase {
  func testProductionSessionAllowsLongPlaybackWithoutDisablingInactivityTimeout() {
    let session = LoopbackStreamRelay.productionSession(delegate: RelayConfigurationDelegate())
    defer { session.invalidateAndCancel() }
    XCTAssertEqual(session.configuration.timeoutIntervalForResource, 12 * 60 * 60)
    XCTAssertEqual(session.configuration.timeoutIntervalForRequest, 30)
    XCTAssertEqual(session.configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    XCTAssertNil(session.configuration.urlCache)
    XCTAssertNil(session.configuration.httpCookieStorage)
  }

  func testGETHEADRangesParallelRequestsAndTicketSwitch() async throws {
    let failures = RelayFailureRecorder()
    let source = URL(string: "https://relay.test/old")!
    let relay = try LoopbackStreamRelay(
      sourceURL: source,
      publicKeyFingerprint: String(repeating: "A", count: 64),
      authorizationToken: "test-device-token",
      sessionFactory: Self.stubSession)
    relay.setFailureHandler { failures.record($0) }
    let localURL = try await relay.start()
    defer { relay.stop() }

    let (full, fullResponse) = try await URLSession.shared.data(from: localURL)
    XCTAssertEqual((fullResponse as? HTTPURLResponse)?.statusCode, 200)
    XCTAssertEqual(full, RelayURLProtocol.oldPayload)
    XCTAssertEqual((fullResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Cache-Control"), "private, no-store")

    var headRequest = URLRequest(url: localURL)
    headRequest.httpMethod = "HEAD"
    let (head, headResponse) = try await URLSession.shared.data(for: headRequest)
    XCTAssertEqual((headResponse as? HTTPURLResponse)?.statusCode, 200)
    XCTAssertTrue(head.isEmpty)

    let middle = try await Self.range("bytes=2-5", from: localURL)
    XCTAssertEqual(middle.0, Data(RelayURLProtocol.oldPayload[2...5]))
    XCTAssertEqual(middle.1.statusCode, 206)
    XCTAssertEqual(middle.1.value(forHTTPHeaderField: "Content-Range"), "bytes 2-5/16")

    let suffix = try await Self.range("bytes=-3", from: localURL)
    XCTAssertEqual(suffix.0, Data(RelayURLProtocol.oldPayload.suffix(3)))
    let open = try await Self.range("bytes=13-", from: localURL)
    XCTAssertEqual(open.0, Data(RelayURLProtocol.oldPayload.suffix(3)))

    async let first = Self.range("bytes=0-1", from: localURL)
    async let second = Self.range("bytes=6-9", from: localURL)
    let (firstResult, secondResult) = try await (first, second)
    XCTAssertEqual(firstResult.0, Data(RelayURLProtocol.oldPayload[0...1]))
    XCTAssertEqual(secondResult.0, Data(RelayURLProtocol.oldPayload[6...9]))

    let unsatisfied = try await Self.range("bytes=100-110", from: localURL)
    XCTAssertEqual(unsatisfied.1.statusCode, 416)

    relay.updateSourceURL(URL(string: "https://relay.test/new")!)
    let (renewed, _) = try await URLSession.shared.data(from: localURL)
    XCTAssertEqual(renewed, RelayURLProtocol.newPayload)
    XCTAssertEqual(
      RelayURLProtocol.authorizationRecorder.latestValue,
      "Bearer test-device-token")
    XCTAssertTrue(failures.values.isEmpty)
  }

  func testWrongSecretAndMethodStayLocalAndAreRejected() async throws {
    let relay = try LoopbackStreamRelay(
      sourceURL: URL(string: "https://relay.test/old")!,
      publicKeyFingerprint: String(repeating: "A", count: 64),
      sessionFactory: Self.stubSession)
    let localURL = try await relay.start()
    defer { relay.stop() }
    XCTAssertEqual(localURL.host, "127.0.0.1")

    let wrongURL = localURL.deletingLastPathComponent().appendingPathComponent("wrong")
    let (_, wrongResponse) = try await URLSession.shared.data(from: wrongURL)
    XCTAssertEqual((wrongResponse as? HTTPURLResponse)?.statusCode, 400)

    var post = URLRequest(url: localURL)
    post.httpMethod = "POST"
    let (_, postResponse) = try await URLSession.shared.data(for: post)
    XCTAssertEqual((postResponse as? HTTPURLResponse)?.statusCode, 400)
  }

  func testTruncatedAndInterruptedTransfersReportFailureInsteadOfSuccessfulEnd() async throws {
    for path in ["truncated", "interrupted"] {
      try await assertFailure(path: path, expected: .interrupted)
    }
  }

  func testAuthorizationUnavailableInvalidAndTrustFailuresRemainDistinct() async throws {
    for (path, failure) in [
      ("denied", PlaybackStreamFailure.authorizationDenied),
      ("forbidden", .authorizationDenied),
      ("missing", .unavailable),
      ("badlength", .invalidResponse),
      ("tlsfailure", .untrustedServer),
      ("oversized", .interrupted),
    ] {
      try await assertFailure(path: path, expected: failure)
    }
  }

  func testLocalSeekCancellationStopsWaitingUpstreamWithoutReportingOutage() async throws {
    let failures = RelayFailureRecorder()
    let stopped = expectation(description: "Canceled local stream cancels upstream")
    RelayURLProtocol.cancellationRecorder.setHandler { stopped.fulfill() }
    defer { RelayURLProtocol.cancellationRecorder.setHandler(nil) }
    let relay = try LoopbackStreamRelay(
      sourceURL: URL(string: "https://relay.test/waiting")!,
      publicKeyFingerprint: String(repeating: "A", count: 64),
      sessionFactory: Self.stubSession)
    relay.setFailureHandler { failures.record($0) }
    let localURL = try await relay.start()
    defer { relay.stop() }
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let request = session.dataTask(with: localURL)
    request.resume()
    // Wait for the upstream response rather than assuming a network timing.
    let started = expectation(description: "Waiting upstream started")
    RelayURLProtocol.cancellationRecorder.setStartedHandler { started.fulfill() }
    defer { RelayURLProtocol.cancellationRecorder.setStartedHandler(nil) }
    await fulfillment(of: [started], timeout: 5)
    request.cancel()
    await fulfillment(of: [stopped], timeout: 5)
    XCTAssertTrue(failures.values.isEmpty)
  }

  func testStoppingDuringUpstreamSessionCreationCannotStartLateReads() async throws {
    let factoryEntered = expectation(description: "Upstream factory entered")
    let factoryReturned = expectation(description: "Upstream factory returned")
    let releaseFactory = DispatchSemaphore(value: 0)
    let path = "/late-\(UUID().uuidString)"
    let failures = RelayFailureRecorder()
    let relay = try LoopbackStreamRelay(
      sourceURL: URL(string: "https://relay.test\(path)")!,
      publicKeyFingerprint: String(repeating: "A", count: 64),
      sessionFactory: { delegate in
        factoryEntered.fulfill()
        _ = releaseFactory.wait(timeout: .now() + 5)
        let session = Self.stubSession(delegate: delegate)
        factoryReturned.fulfill()
        return session
      })
    relay.setFailureHandler { failures.record($0) }
    defer {
      releaseFactory.signal()
      relay.stop()
    }
    let localURL = try await relay.start()
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let localFinished = expectation(description: "Stopped local request finishes")
    let request = session.dataTask(with: localURL) { _, _, _ in localFinished.fulfill() }
    request.resume()
    await fulfillment(of: [factoryEntered], timeout: 5)
    relay.stop()
    releaseFactory.signal()
    await fulfillment(of: [factoryReturned, localFinished], timeout: 5)
    // Allow already scheduled Foundation callbacks to settle after the forced
    // factory/stop race; no network request may begin on that retired relay.
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(RelayURLProtocol.requestRecorder.count(for: path), 0)
    XCTAssertTrue(failures.values.isEmpty)
  }

  private func assertFailure(path: String, expected: PlaybackStreamFailure) async throws {
    let reported = expectation(description: "Reports \(path)")
    reported.assertForOverFulfill = true
    let failures = RelayFailureRecorder()
    let relay = try LoopbackStreamRelay(
      sourceURL: URL(string: "https://relay.test/\(path)")!,
      publicKeyFingerprint: String(repeating: "A", count: 64),
      sessionFactory: Self.stubSession)
    relay.setFailureHandler {
      failures.record($0)
      reported.fulfill()
    }
    let localURL = try await relay.start()
    defer { relay.stop() }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 5
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    do {
      _ = try await session.data(from: localURL)
    } catch {
      // Aborting a partial HTTP body is expected; the controller receives the
      // independent typed event instead of treating this as normal media EOF.
    }
    await fulfillment(of: [reported], timeout: 5)
    XCTAssertEqual(failures.values, [expected])
  }

  private static func range(
    _ value: String,
    from url: URL
  ) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: url)
    request.setValue(value, forHTTPHeaderField: "Range")
    request.setValue("\"relay-etag\"", forHTTPHeaderField: "If-Range")
    let (data, response) = try await URLSession.shared.data(for: request)
    return (data, try XCTUnwrap(response as? HTTPURLResponse))
  }

  private static func stubSession(delegate: URLSessionDelegate) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RelayURLProtocol.self]
    return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
  }
}

private final class RelayConfigurationDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {}

private final class RelayURLProtocol: URLProtocol, @unchecked Sendable {
  static let oldPayload = Data("0123456789ABCDEF".utf8)
  static let newPayload = Data("renewed-ticket".utf8)
  static let authorizationRecorder = AuthorizationRecorder()
  static let cancellationRecorder = RelayCancellationRecorder()
  static let requestRecorder = RelayRequestRecorder()

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "relay.test"
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.requestRecorder.record(request.url?.path ?? "")
    Self.authorizationRecorder.record(request.value(forHTTPHeaderField: "Authorization"))
    let path = request.url?.path ?? ""
    if path == "/tlsfailure" {
      client?.urlProtocol(self, didFailWithError: URLError(.serverCertificateUntrusted))
      return
    }
    if ["/denied", "/forbidden", "/missing"].contains(path) {
      let status = path == "/denied" ? 401 : path == "/forbidden" ? 403 : 404
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Length": "0"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocolDidFinishLoading(self)
      return
    }
    if ["/truncated", "/interrupted", "/badlength", "/oversized", "/waiting"].contains(path) {
      let payload = path == "/oversized" ? Data(repeating: 65, count: 2_097_152) : Data("partial".utf8)
      let length = path == "/badlength" ? "-1" : path == "/oversized" ? String(payload.count) : "16"
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Length": length, "Content-Type": "video/x-matroska"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      if path == "/waiting" { Self.cancellationRecorder.didStart() }
      client?.urlProtocol(self, didLoad: payload)
      if path == "/interrupted" {
        client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
      } else if path != "/waiting" {
        client?.urlProtocolDidFinishLoading(self)
      }
      return
    }
    let payload = request.url?.path == "/new" ? Self.newPayload : Self.oldPayload
    let range = request.value(forHTTPHeaderField: "Range")
    let result = Self.response(for: range, payload: payload)
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: result.status,
      httpVersion: "HTTP/1.1",
      headerFields: [
        "Content-Type": "video/x-matroska",
        "Content-Length": String(result.data.count),
        "Content-Range": result.contentRange ?? "",
        "Accept-Ranges": "bytes",
        "ETag": "\"relay-etag\"",
      ])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if request.httpMethod != "HEAD", !result.data.isEmpty {
      client?.urlProtocol(self, didLoad: result.data)
    }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {
    if request.url?.path == "/waiting" { Self.cancellationRecorder.didCancel() }
  }

  private static func response(
    for range: String?,
    payload: Data
  ) -> (status: Int, data: Data, contentRange: String?) {
    guard let range else { return (200, payload, nil) }
    let value = range.dropFirst("bytes=".count)
    let parts = value.split(separator: "-", omittingEmptySubsequences: false)
    if parts[0].isEmpty, let count = Int(parts[1]), count > 0 {
      let start = max(0, payload.count - count)
      return (206, Data(payload[start...]), "bytes \(start)-\(payload.count - 1)/\(payload.count)")
    }
    guard let start = Int(parts[0]), start < payload.count else {
      return (416, Data(), "bytes */\(payload.count)")
    }
    let end = parts[1].isEmpty
      ? payload.count - 1
      : min(Int(parts[1]) ?? payload.count - 1, payload.count - 1)
    return (206, Data(payload[start...end]), "bytes \(start)-\(end)/\(payload.count)")
  }
}

private final class RelayFailureRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [PlaybackStreamFailure] = []
  var values: [PlaybackStreamFailure] { lock.withLock { recorded } }
  func record(_ value: PlaybackStreamFailure) { lock.withLock { recorded.append(value) } }
}

private final class RelayRequestRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var requests: [String: Int] = [:]
  func record(_ path: String) { lock.withLock { requests[path, default: 0] += 1 } }
  func count(for path: String) -> Int { lock.withLock { requests[path, default: 0] } }
}

private final class RelayCancellationRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var canceled: (@Sendable () -> Void)?
  private var started: (@Sendable () -> Void)?
  private var hasStarted = false

  func setHandler(_ handler: (@Sendable () -> Void)?) {
    lock.withLock {
      canceled = handler
      hasStarted = false
    }
  }
  func setStartedHandler(_ handler: (@Sendable () -> Void)?) {
    let invoke = lock.withLock {
      started = handler
      return hasStarted ? handler : nil
    }
    invoke?()
  }
  func didStart() {
    let invoke = lock.withLock {
      hasStarted = true
      return started
    }
    invoke?()
  }
  func didCancel() { lock.withLock { canceled }?() }
}

private final class AuthorizationRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var value: String?

  var latestValue: String? {
    lock.withLock { value }
  }

  func record(_ value: String?) {
    lock.withLock { self.value = value }
  }
}
