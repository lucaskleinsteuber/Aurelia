import Foundation
@preconcurrency import Network
import XCTest

final class TVStreamRelayTests: XCTestCase {
  func testProductionSessionAllowsLongPlaybackWithoutDisablingInactivityTimeout() {
    let session = TVStreamRelay.productionSession(delegate: RelayConfigurationDelegate())
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
    let relay = try TVStreamRelay(
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
    XCTAssertEqual(
      (fullResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Cache-Control"),
      "private, no-store")

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

  func testSequentialRangeRequestsReuseOneVerifiedUpstreamSession() async throws {
    let failures = RelayFailureRecorder()
    let relay = try TVStreamRelay(
      sourceURL: URL(string: "https://relay.test/old")!,
      publicKeyFingerprint: String(repeating: "A", count: 64),
      sessionFactory: Self.stubSession)
    relay.setFailureHandler { failures.record($0) }
    let localURL = try await relay.start()
    defer { relay.stop() }
    // Each seek opens a new local request; the upstream connection is reused.
    for (range, expected) in [
      ("bytes=0-3", RelayURLProtocol.oldPayload[0...3]),
      ("bytes=8-11", RelayURLProtocol.oldPayload[8...11]),
      ("bytes=4-7", RelayURLProtocol.oldPayload[4...7]),
    ] {
      let (data, response) = try await Self.range(range, from: localURL)
      XCTAssertEqual(response.statusCode, 206)
      XCTAssertEqual(data, Data(expected))
    }
    XCTAssertEqual(relay.upstreamSessionCount, 1)
    XCTAssertTrue(failures.values.isEmpty)
  }

  func testCancelledSeekReturnsItsSessionForTheNextRange() async throws {
    let failures = RelayFailureRecorder()
    let relay = try TVStreamRelay(
      sourceURL: URL(string: "https://relay.test/waiting")!,
      publicKeyFingerprint: String(repeating: "A", count: 64),
      sessionFactory: Self.stubSession)
    relay.setFailureHandler { failures.record($0) }
    let localURL = try await relay.start()
    defer { relay.stop() }
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let started = expectation(description: "Waiting upstream started")
    RelayURLProtocol.cancellationRecorder.setStartedHandler { started.fulfill() }
    defer { RelayURLProtocol.cancellationRecorder.setStartedHandler(nil) }
    let stopped = expectation(description: "Cancelled seek stops its upstream transfer")
    RelayURLProtocol.cancellationRecorder.setHandler { stopped.fulfill() }
    defer { RelayURLProtocol.cancellationRecorder.setHandler(nil) }
    let request = session.dataTask(with: localURL)
    request.resume()
    await fulfillment(of: [started], timeout: 5)
    request.cancel()
    await fulfillment(of: [stopped], timeout: 5)

    // The next range after the seek uses the same session, and a late callback
    // of the cancelled transfer cannot reach it.
    relay.updateSourceURL(URL(string: "https://relay.test/old")!)
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    var reused = false
    while ContinuousClock.now < deadline {
      let (data, response) = try await Self.range("bytes=2-5", from: localURL)
      XCTAssertEqual(response.statusCode, 206)
      XCTAssertEqual(data, Data(RelayURLProtocol.oldPayload[2...5]))
      if relay.upstreamSessionCount == 1 {
        reused = true
        break
      }
    }
    XCTAssertTrue(reused, "The session of the cancelled seek is reused.")
    XCTAssertTrue(failures.values.isEmpty)
  }

  func testParallelRequestsUseSeparateSessionsAndThePoolStaysBounded() async throws {
    let relay = try TVStreamRelay(
      sourceURL: URL(string: "https://relay.test/old")!,
      publicKeyFingerprint: String(repeating: "A", count: 64),
      sessionFactory: Self.stubSession)
    let localURL = try await relay.start()
    defer { relay.stop() }
    async let first = Self.range("bytes=0-1", from: localURL)
    async let second = Self.range("bytes=2-3", from: localURL)
    async let third = Self.range("bytes=4-5", from: localURL)
    let results = try await [first, second, third]
    XCTAssertEqual(
      results.map(\.0),
      [
        Data(RelayURLProtocol.oldPayload[0...1]), Data(RelayURLProtocol.oldPayload[2...3]),
        Data(RelayURLProtocol.oldPayload[4...5]),
      ])
    XCTAssertGreaterThanOrEqual(relay.upstreamSessionCount, 1)
    XCTAssertLessThanOrEqual(relay.upstreamSessionCount, 3)
    let before = relay.upstreamSessionCount
    for _ in 0..<4 { _ = try await Self.range("bytes=6-7", from: localURL) }
    XCTAssertEqual(relay.upstreamSessionCount, before, "Idle sessions are reused, not recreated.")
  }

  func testWrongSecretAndMethodStayLocalAndAreRejected() async throws {
    let relay = try TVStreamRelay(
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
    try await assertFailure(path: "truncated", expected: .interrupted)
    try await assertFailure(path: "interrupted", expected: .interrupted)
  }

  func testAuthorizationUnavailableInvalidAndTrustFailuresRemainDistinct() async throws {
    for (path, failure) in [
      ("denied", TVStreamFailure.server(status: 401, code: nil)),
      ("forbidden", .server(status: 403, code: nil)),
      ("missing", .server(status: 404, code: nil)),
      ("badlength", .invalidResponse),
      ("tlsfailure", .untrustedServer),
    ] {
      try await assertFailure(path: path, expected: failure)
    }
  }

  func testLargeValidCallbackUsesBackpressureInsteadOfReportingAnOutage() async throws {
    let failures = RelayFailureRecorder()
    let relay = try TVStreamRelay(
      sourceURL: URL(string: "https://relay.test/oversized")!,
      publicKeyFingerprint: String(repeating: "A", count: 64),
      sessionFactory: Self.stubSession)
    relay.setFailureHandler { failures.record($0) }
    let localURL = try await relay.start()
    defer { relay.stop() }
    let (data, response) = try await URLSession.shared.data(from: localURL)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    XCTAssertEqual(data, Data(repeating: 65, count: 2_097_152))
    XCTAssertTrue(failures.values.isEmpty)
  }

  func testLocalSeekCancellationStopsWaitingUpstreamWithoutReportingOutage() async throws {
    let failures = RelayFailureRecorder()
    let stopped = expectation(description: "Canceled local stream cancels upstream")
    RelayURLProtocol.cancellationRecorder.setHandler { stopped.fulfill() }
    defer { RelayURLProtocol.cancellationRecorder.setHandler(nil) }
    let relay = try TVStreamRelay(
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

  func testRelayStopReturnsLargeCallbackAndAllowsFreshStreamWithoutOutage() async throws {
    try await assertLargeCallbackCancellation(stopRelay: true)
  }

  func testLocalCancellationReturnsLargeCallbackAndAllowsFreshStreamWithoutOutage() async throws {
    try await assertLargeCallbackCancellation(stopRelay: false)
  }

  func testCancellationWakesProducerWaitingAtBoundedWindowCapacity() async throws {
    let capacity = 1_048_576
    let window = TVRelayBufferWindow(maximumBytes: capacity)
    defer { window.cancel() }
    XCTAssertTrue(window.reserve(capacity))
    let returned = expectation(description: "Blocked reservation returns on cancellation")
    let result = RelayReservationResult()
    DispatchQueue(label: "relay-test.capacity-waiter").async {
      result.record(window.reserve(65_536))
      returned.fulfill()
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while window.waitingProducerCount != 1, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(window.waitingProducerCount, 1)
    window.cancel()
    await fulfillment(of: [returned], timeout: 1)
    XCTAssertEqual(result.value, false)
    XCTAssertEqual(window.waitingProducerCount, 0)
    // A late downstream completion cannot revive a canceled window.
    window.release(capacity)
    XCTAssertFalse(window.reserve(65_536))
  }

  func testInvalidWindowReservationCannotWaitForever() {
    let window = TVRelayBufferWindow(maximumBytes: 65_536)
    XCTAssertFalse(window.reserve(-1))
    XCTAssertFalse(window.reserve(65_537))
    XCTAssertTrue(window.reserve(65_536))
    window.cancel()
  }

  /// Only the status and the problem code reach the player; messages never do,
  /// and an oversized problem document is not parsed.
  func testProblemCodesArePreservedWithoutRawErrorText() async throws {
    for (path, failure) in [
      ("offline", TVStreamFailure.server(status: 503, code: "media_unavailable")),
      ("unsafe", .server(status: 409, code: "media_file_unavailable")),
      ("busy", .server(status: 429, code: "stream_limit")),
      ("unlisted", .server(status: 503, code: "private-unlisted-value")),
      ("hugeproblem", .server(status: 503, code: nil)),
    ] {
      try await assertFailure(path: path, expected: failure)
    }
  }

  func testStoppingDuringUpstreamSessionCreationCannotStartLateReads() async throws {
    let factoryEntered = expectation(description: "Upstream factory entered")
    let factoryReturned = expectation(description: "Upstream factory returned")
    let releaseFactory = DispatchSemaphore(value: 0)
    let path = "/late-\(UUID().uuidString)"
    let failures = RelayFailureRecorder()
    let relay = try TVStreamRelay(
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

  private func assertFailure(path: String, expected: TVStreamFailure) async throws {
    let reported = expectation(description: "Reports \(path)")
    reported.assertForOverFulfill = true
    let failures = RelayFailureRecorder()
    let relay = try TVStreamRelay(
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

  private func assertLargeCallbackCancellation(stopRelay: Bool) async throws {
    let failures = RelayFailureRecorder()
    let probe = RelayBurstProbe(
      started: expectation(description: "Large Foundation callback entered"),
      returned: expectation(description: "Large Foundation callback returned after cancellation"),
      stopped: expectation(description: "Still-open synthetic upstream canceled"))
    let path = "/burst-\(UUID().uuidString)"
    RelayBurstURLProtocol.probes.insert(probe, for: path)
    defer { RelayBurstURLProtocol.probes.remove(for: path) }
    let sessionFactory: TVStreamRelay.SessionFactory = { delegate in
      let configuration = URLSessionConfiguration.ephemeral
      configuration.protocolClasses = [RelayBurstURLProtocol.self]
      return URLSession(
        configuration: configuration,
        delegate: RelayBurstObservingDelegate(delegate: delegate, probe: probe),
        delegateQueue: nil)
    }
    let relay = try TVStreamRelay(
      sourceURL: URL(string: "https://backpressure.relay.test\(path)")!,
      publicKeyFingerprint: String(repeating: "A", count: 64),
      sessionFactory: sessionFactory)
    relay.setFailureHandler { failures.record($0) }
    let localURL = try await relay.start()
    let port = try XCTUnwrap(localURL.port.flatMap { UInt16(exactly: $0) })
    let connection = NWConnection(
      host: "127.0.0.1", port: try XCTUnwrap(NWEndpoint.Port(rawValue: port)), using: .tcp)
    defer {
      connection.cancel()
      relay.stop()
    }
    let ready = RelayOnceExpectation(expectation(description: "Non-reading TCP client connected"))
    connection.stateUpdateHandler = { state in
      if case .ready = state { ready.fulfill() }
    }
    connection.start(queue: DispatchQueue(label: "relay-test.non-reading-client"))
    await fulfillment(of: [ready.expectation], timeout: 5)
    guard ready.isFulfilled else { return }

    // Deliberately never call receive on this connection. OS socket buffering
    // may still absorb this burst; this integration test does not claim that
    // the application window blocked. The window test proves that separately.
    let sent = RelayOnceExpectation(expectation(description: "Local GET sent"))
    let request = "GET \(localURL.path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n"
    connection.send(
      content: Data(request.utf8),
      completion: .contentProcessed { error in
        probe.recordLocalSend(error == nil)
        sent.fulfill()
      })
    await fulfillment(of: [sent.expectation, probe.started.expectation], timeout: 5)
    XCTAssertTrue(probe.localSendSucceeded)
    guard probe.started.isFulfilled else { return }
    XCTAssertEqual(probe.callbackBytes, RelayBurstURLProtocol.burstBytes)

    let cancelledAt = ContinuousClock.now
    if stopRelay {
      relay.stop()
    } else {
      connection.cancel()
    }
    await fulfillment(of: [probe.returned.expectation, probe.stopped.expectation], timeout: 5)
    XCTAssertLessThan(cancelledAt.duration(to: .now), .seconds(5))
    XCTAssertTrue(probe.returned.isFulfilled)
    XCTAssertTrue(probe.stopped.isFulfilled)
    XCTAssertTrue(failures.values.isEmpty)

    // Local cancellation keeps the same listener usable; stopping retires it,
    // so use a new relay with the same upstream test transport in that case.
    let freshRelay: TVStreamRelay
    let freshURL: URL
    let source = URL(string: "https://backpressure.relay.test/fresh")!
    if stopRelay {
      freshRelay = try TVStreamRelay(
        sourceURL: source,
        publicKeyFingerprint: String(repeating: "A", count: 64),
        sessionFactory: sessionFactory)
      freshRelay.setFailureHandler { failures.record($0) }
      freshURL = try await freshRelay.start()
    } else {
      freshRelay = relay
      freshRelay.updateSourceURL(source)
      freshURL = localURL
    }
    defer { freshRelay.stop() }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 5
    configuration.timeoutIntervalForResource = 5
    let client = URLSession(configuration: configuration)
    defer { client.invalidateAndCancel() }
    let (data, response) = try await client.data(from: freshURL)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    XCTAssertEqual(data, RelayBurstURLProtocol.freshPayload)
    XCTAssertTrue(failures.values.isEmpty)
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

private final class RelayReservationResult: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: Bool?
  var value: Bool? { lock.withLock { recorded } }
  func record(_ value: Bool) { lock.withLock { recorded = value } }
}

private final class RelayOnceExpectation: @unchecked Sendable {
  let expectation: XCTestExpectation
  private let lock = NSLock()
  private var fulfilled = false

  init(_ expectation: XCTestExpectation) { self.expectation = expectation }
  var isFulfilled: Bool { lock.withLock { fulfilled } }
  func fulfill() {
    let first = lock.withLock {
      guard !fulfilled else { return false }
      fulfilled = true
      return true
    }
    if first { expectation.fulfill() }
  }
}

private final class RelayBurstProbe: @unchecked Sendable {
  let started: RelayOnceExpectation
  let returned: RelayOnceExpectation
  let stopped: RelayOnceExpectation
  private let lock = NSLock()
  private var observedBytes = 0
  private var sendSucceeded = false

  init(started: XCTestExpectation, returned: XCTestExpectation, stopped: XCTestExpectation) {
    self.started = RelayOnceExpectation(started)
    self.returned = RelayOnceExpectation(returned)
    self.stopped = RelayOnceExpectation(stopped)
  }
  var callbackBytes: Int { lock.withLock { observedBytes } }
  var localSendSucceeded: Bool { lock.withLock { sendSucceeded } }
  func recordLocalSend(_ succeeded: Bool) { lock.withLock { sendSucceeded = succeeded } }
  func callbackStarted(bytes: Int) {
    lock.withLock {
      if observedBytes == 0 { observedBytes = bytes }
    }
    started.fulfill()
  }
}

private final class RelayBurstProbeRegistry: @unchecked Sendable {
  private let lock = NSLock()
  private var probes: [String: RelayBurstProbe] = [:]
  func insert(_ probe: RelayBurstProbe, for path: String) {
    lock.withLock { probes[path] = probe }
  }
  func remove(for path: String) { _ = lock.withLock { probes.removeValue(forKey: path) } }
  func value(for path: String) -> RelayBurstProbe? { lock.withLock { probes[path] } }
}

// This synthetic-only adapter observes the exact Foundation data callback, not
// merely URLProtocol delivery. The relay retains its normal serial delegate
// queue; the adapter is not used for TLS or identity-validation coverage.
private final class RelayBurstObservingDelegate: NSObject, URLSessionDataDelegate,
  @unchecked Sendable
{
  private let delegate: URLSessionDataDelegate
  private let probe: RelayBurstProbe

  init(delegate: URLSessionDelegate, probe: RelayBurstProbe) {
    self.delegate = delegate as! URLSessionDataDelegate
    self.probe = probe
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    delegate.urlSession?(
      session, dataTask: dataTask, didReceive: response, completionHandler: completionHandler)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    probe.callbackStarted(bytes: data.count)
    defer { probe.returned.fulfill() }
    delegate.urlSession?(session, dataTask: dataTask, didReceive: data)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    delegate.urlSession?(session, task: task, didCompleteWithError: error)
  }
}

private final class RelayBurstURLProtocol: URLProtocol, @unchecked Sendable {
  static let burstBytes = 16 * 1_048_576
  static let freshPayload = Data("fresh-after-cancellation".utf8)
  static let probes = RelayBurstProbeRegistry()

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "backpressure.relay.test"
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let fresh = request.url?.path == "/fresh"
    let payload = fresh ? Self.freshPayload : Data(repeating: 65, count: Self.burstBytes)
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
      headerFields: [
        "Content-Length": String(payload.count + (fresh ? 0 : 1)),
        "Content-Type": "video/x-matroska",
      ])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: payload)
    // Keep the burst upstream active even if socket buffers absorb every byte:
    // cancellation, not a successful EOF, must produce stopLoading.
    if fresh { client?.urlProtocolDidFinishLoading(self) }
  }

  override func stopLoading() {
    if let path = request.url?.path { Self.probes.value(for: path)?.stopped.fulfill() }
  }
}

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
    if ["/offline", "/unsafe", "/busy", "/unlisted", "/hugeproblem"].contains(path) {
      let status = path == "/unsafe" ? 409 : path == "/busy" ? 429 : 503
      let code =
        path == "/offline"
        ? "media_unavailable"
        : path == "/unsafe"
          ? "media_file_unavailable"
          : path == "/busy" ? "stream_limit" : "private-unlisted-value"
      let body =
        path == "/hugeproblem"
        ? Data(repeating: 65, count: 32_768)
        : try! JSONSerialization.data(withJSONObject: [
          "code": code, "message": "Synthetic private token/path that must never escape",
        ])
      var headers = ["Content-Length": String(body.count), "Content-Type": "application/json"]
      if path == "/offline" { headers["Retry-After"] = "2" }
      if path == "/busy" { headers["Retry-After"] = "60" }
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: body)
      client?.urlProtocolDidFinishLoading(self)
      return
    }
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
      let payload =
        path == "/oversized" ? Data(repeating: 65, count: 2_097_152) : Data("partial".utf8)
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
    let end =
      parts[1].isEmpty
      ? payload.count - 1
      : min(Int(parts[1]) ?? payload.count - 1, payload.count - 1)
    return (206, Data(payload[start...end]), "bytes \(start)-\(end)/\(payload.count)")
  }
}

private final class RelayFailureRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [TVStreamFailure] = []
  var values: [TVStreamFailure] { lock.withLock { recorded } }
  func record(_ value: TVStreamFailure) { lock.withLock { recorded.append(value) } }
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
