import Foundation
import XCTest

@testable import Aurelia

final class LoopbackStreamRelayTests: XCTestCase {
  func testGETHEADRangesParallelRequestsAndTicketSwitch() async throws {
    let source = URL(string: "https://relay.test/old")!
    let relay = try LoopbackStreamRelay(
      sourceURL: source,
      publicKeyFingerprint: String(repeating: "A", count: 64),
      authorizationToken: "test-device-token",
      sessionFactory: Self.stubSession)
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

private final class RelayURLProtocol: URLProtocol, @unchecked Sendable {
  static let oldPayload = Data("0123456789ABCDEF".utf8)
  static let newPayload = Data("renewed-ticket".utf8)
  static let authorizationRecorder = AuthorizationRecorder()

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "relay.test"
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.authorizationRecorder.record(request.value(forHTTPHeaderField: "Authorization"))
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

  override func stopLoading() {}

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
