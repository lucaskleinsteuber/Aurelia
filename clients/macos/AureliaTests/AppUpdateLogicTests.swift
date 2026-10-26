import Foundation
import Testing

@testable import Aurelia

struct AppUpdateLogicTests {
  @Test
  func tagsAreVersionAndBuild() {
    #expect(AppUpdateLogic.parseTag("1.12.1-99")! == ("1.12.1", 99))
    #expect(AppUpdateLogic.parseTag("1.12-99") == nil)
    #expect(AppUpdateLogic.parseTag("v1.12.1") == nil)
    #expect(AppUpdateLogic.parseTag("1.12.1-0") == nil)
    #expect(AppUpdateLogic.isNewer(build: 100, than: 99))
    #expect(!AppUpdateLogic.isNewer(build: 99, than: 99))
  }

  @Test(arguments: [
    "1..13.0-101", "1.13.0--101", "1.13.0-101-", "01.13.0-101", "1.13.+0-101",
    "1.13.0-+101", "1.13.0-0101", "1.13.0-", "1.13.0-9999999999999999999999999",
  ])
  func malformedTagsAreRejected(tag: String) {
    #expect(AppUpdateLogic.parseTag(tag) == nil)
  }

  @Test
  func checksumsAreReadFromTheReleaseList() {
    let hash = String(repeating: "ab", count: 32)
    let sums = """
      \(String(repeating: "0", count: 64))  ./Aurelia-Server-1.12.1-99-linux-x64.tar.gz
      \(hash.uppercased())  ./Aurelia-1.12.1-99-macOS-universal.dmg
      """
    #expect(AppUpdateLogic.checksum(for: "Aurelia-1.12.1-99-macOS-universal.dmg", in: sums) == hash)
    #expect(AppUpdateLogic.checksum(for: "Missing.dmg", in: sums) == nil)
  }

  @Test
  func theLatestReleaseNeedsItsDiskImageAndChecksums() throws {
    let release = """
      {"tag_name":"1.13.0-100","draft":false,"html_url":"https://github.com/owner/repo/releases/tag/1.13.0-100",
       "assets":[
        {"name":"Aurelia-1.13.0-100-macOS-universal.dmg","url":"https://api.github.com/repos/owner/repo/releases/assets/1"},
        {"name":"SHA256SUMS","url":"https://api.github.com/repos/owner/repo/releases/assets/2"}]}
      """
    let parsed = try #require(AppUpdateLogic.release(fromLatest: Data(release.utf8)))
    #expect(parsed.version == "1.13.0")
    #expect(parsed.build == 100)
    #expect(parsed.diskImageURL.absoluteString.hasSuffix("/assets/1"))
    #expect(parsed.checksumsURL.absoluteString.hasSuffix("/assets/2"))
    let withoutImage = release.replacingOccurrences(of: "macOS-universal.dmg", with: "other.dmg")
    #expect(AppUpdateLogic.release(fromLatest: Data(withoutImage.utf8)) == nil)
    #expect(AppUpdateLogic.isRepository("lucasfd3/Aurelia"))
    #expect(!AppUpdateLogic.isRepository("https://github.com/x/y"))
    #expect(!AppUpdateLogic.isRepository("x/y/z"))
  }

  @Test func releaseErrorsDistinguishMissingAssetsAndMalformedData() throws {
    #expect(throws: AppUpdateError.noDiskImage) {
      try AppUpdateLogic.validatedRelease(fromLatest: releaseData(imageName: "Other.dmg"))
    }
    #expect(throws: AppUpdateError.noChecksum) {
      try AppUpdateLogic.validatedRelease(fromLatest: releaseData(checksumName: "Other.txt"))
    }
    #expect(throws: AppUpdateError.invalidTag) {
      try AppUpdateLogic.validatedRelease(fromLatest: releaseData(tag: "invalid"))
    }
    for value in ["<html>Sign in</html>", "{}", "not JSON"] {
      #expect(throws: AppUpdateError.invalidRelease) {
        try AppUpdateLogic.validatedRelease(fromLatest: Data(value.utf8))
      }
    }
  }

  @Test(arguments: [
    "http://api.github.com/repos/owner/repo/releases/assets/1",
    "https://api.github.com.evil.invalid/repos/owner/repo/releases/assets/1",
    "https://other.invalid/repos/owner/repo/releases/assets/1",
    "https://api.github.com/repos/other/repo/releases/assets/1",
    "https://api.github.com/repos/owner/repo/releases/assets/1?token=unexpected",
    "https://user@api.github.com/repos/owner/repo/releases/assets/1",
    "https://api.github.com:8443/repos/owner/repo/releases/assets/1",
    "file:///tmp/image.dmg",
  ])
  func assetsCannotSendTokensOutsideTheirRepository(address: String) {
    #expect(throws: AppUpdateError.invalidURL) {
      try AppUpdateLogic.validatedRelease(
        fromLatest: releaseData(imageURL: address), repository: "owner/repo")
    }
  }

  @Test func redirectsDropAllCredentialsAndRejectUnsafeDestinations() throws {
    for address in [
      "https://api.github.com/repos/owner/repo/releases/assets/1",
      "https://release-assets.githubusercontent.com/github-production-release-asset/image?signature=test",
      "https://objects.githubusercontent.com/image",
    ] {
      var request = URLRequest(url: URL(string: address)!)
      for field in ["Authorization", "Cookie", "Proxy-Authorization"] {
        request.setValue("synthetic", forHTTPHeaderField: field)
      }
      let redirected = try #require(AppUpdateLogic.redirectedRequest(request))
      for field in ["Authorization", "Cookie", "Proxy-Authorization"] {
        #expect(redirected.value(forHTTPHeaderField: field) == nil)
      }
    }
    for address in [
      "http://release-assets.githubusercontent.com/image", "https://other.invalid/image",
      "file:///tmp/image", "https://githubusercontent.com.evil.invalid/image",
    ] {
      #expect(AppUpdateLogic.redirectedRequest(URLRequest(url: URL(string: address)!)) == nil)
    }
  }

  @Test func boundedAccumulatorRejectsHTTPHTMLTruncationAndExcessData() throws {
    for status in [401, 403, 404, 500] {
      #expect(throws: AppUpdateError.github(status)) {
        try AppUpdateTransferAccumulator(response: response(status: status), maximumBytes: 16)
      }
    }
    #expect(throws: AppUpdateError.invalidResponse) {
      try AppUpdateTransferAccumulator(response: response(type: "text/html"), maximumBytes: 16)
    }
    #expect(throws: AppUpdateError.tooLarge) {
      try AppUpdateTransferAccumulator(response: response(length: 17), maximumBytes: 16)
    }
    var excess = try AppUpdateTransferAccumulator(response: response(), maximumBytes: 16)
    try excess.consume(Data(repeating: 1, count: 10))
    #expect(throws: AppUpdateError.tooLarge) { try excess.consume(Data(repeating: 1, count: 7)) }
    var truncated = try AppUpdateTransferAccumulator(
      response: response(length: 10), maximumBytes: 16)
    try truncated.consume(Data([1]))
    #expect(throws: AppUpdateError.incompleteDownload) { try truncated.finish() }
    var html = try AppUpdateTransferAccumulator(response: response(), maximumBytes: 64)
    try html.consume(Data("<!doc".utf8))
    #expect(throws: AppUpdateError.invalidResponse) {
      try html.consume(Data("type html><html>Login</html>".utf8))
    }
    var empty = try AppUpdateTransferAccumulator(response: response(), maximumBytes: 16)
    #expect(throws: AppUpdateError.emptyDownload) { try empty.finish() }
  }

  @Test func diskWritesUseIncrementalDigestAndExposeOutOfSpace() throws {
    var written = Data()
    var image = try AppUpdateTransferAccumulator(
      response: response(length: 3), maximumBytes: 16, write: { written.append($0) })
    try image.consume(Data("a".utf8))
    try image.consume(Data("bc".utf8))
    let completed = try image.finish()
    #expect(completed.data.isEmpty)
    #expect(written == Data("abc".utf8))
    #expect(completed.sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    var diskFull = try AppUpdateTransferAccumulator(
      response: response(), maximumBytes: 16,
      write: { _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) })
    do {
      try diskFull.consume(Data([1]))
      Issue.record("A failed write must abort the download.")
    } catch { #expect(AppUpdateError.classify(error) == .diskFull) }
    #expect(AppUpdateError.classify(URLError(.timedOut)) == .timedOut)
    #expect(AppUpdateError.classify(URLError(.networkConnectionLost)) == .connectionLost)
    #expect(
      AppUpdateError.classify(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError))
        == .diskFull)
  }

  @Test func updateQuitStopsBackgroundHostWithoutChangingOrdinaryQuitPolicy() {
    #expect(
      !AppUpdateLogic.shouldStopHost(
        isHosting: true, isBackgroundService: true, installingUpdate: false))
    #expect(
      AppUpdateLogic.shouldStopHost(
        isHosting: true, isBackgroundService: true, installingUpdate: true))
    #expect(
      AppUpdateLogic.shouldStopHost(
        isHosting: true, isBackgroundService: false, installingUpdate: false))
    #expect(
      !AppUpdateLogic.shouldStopHost(
        isHosting: false, isBackgroundService: false, installingUpdate: true))
  }

  @Test func successfulDownloadChecksTheDigestAndUsesPrivateUniqueWorkspace() async throws {
    let folder = try testFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let transport = StubUpdateTransport(steps: [
      .body(releaseData()), .body(checksums()), .body(Data("abc".utf8)),
    ])
    let client = AppUpdateClient(transport: transport)
    let release = try await client.latest(repository: "owner/repo", token: "synthetic-test-token")
    let image = try await client.download(
      release, repository: "owner/repo", token: "synthetic-test-token", currentBuild: 99,
      folder: folder)
    #expect(try Data(contentsOf: image) == Data("abc".utf8))
    #expect(image.deletingLastPathComponent().deletingLastPathComponent() == folder)
    let modes = try FileManager.default.attributesOfItem(
      atPath: image.deletingLastPathComponent().path)
    #expect((modes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    let requests = await transport.requests
    #expect(requests.count == 3)
    #expect(requests[1].value(forHTTPHeaderField: "Accept") == "application/octet-stream")
  }

  @Test(arguments: [
    AppUpdateError.timedOut, .connectionLost, .diskFull, .github(401), .github(403),
    .invalidResponse,
  ])
  func failedDownloadCleansPartialImageAndPreservesSpecificFailure(failure: AppUpdateError)
    async throws
  {
    let folder = try testFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let transport = StubUpdateTransport(steps: [.body(checksums()), .partialFailure(failure)])
    let client = AppUpdateClient(transport: transport)
    let release = try AppUpdateLogic.validatedRelease(
      fromLatest: releaseData(), repository: "owner/repo")
    do {
      _ = try await client.download(
        release, repository: "owner/repo", token: "synthetic-test-token", currentBuild: 99,
        folder: folder)
      Issue.record("A failed download must never reach the installer.")
    } catch let error as AppUpdateError { #expect(error == failure) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
  }

  @Test func wrongChecksumAndMissingChecksumDoNotLeaveDownloadedFiles() async throws {
    for steps: [StubUpdateTransport.Step] in [
      [.body(checksums()), .body(Data("tampered".utf8))],
      [.body(Data("no checksum".utf8))],
    ] {
      let folder = try testFolder()
      defer { try? FileManager.default.removeItem(at: folder) }
      let client = AppUpdateClient(transport: StubUpdateTransport(steps: steps))
      let release = try AppUpdateLogic.validatedRelease(fromLatest: releaseData())
      do {
        _ = try await client.download(
          release, repository: "owner/repo", token: "synthetic-test-token", currentBuild: 99,
          folder: folder)
        Issue.record("An unchecked image must never reach the installer.")
      } catch let error as AppUpdateError {
        #expect(error == (steps.count == 1 ? .noChecksum : .checksumMismatch))
      }
      #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }
  }

  @Test(arguments: [100, 101])
  func nonNewerReleaseNeverStartsADownload(currentBuild: Int) async throws {
    let transport = StubUpdateTransport(steps: [])
    let client = AppUpdateClient(transport: transport)
    let release = try AppUpdateLogic.validatedRelease(fromLatest: releaseData())
    do {
      _ = try await client.download(
        release, repository: "owner/repo", token: "synthetic-test-token",
        currentBuild: currentBuild,
        folder: URL(fileURLWithPath: "/does-not-exist"))
      Issue.record("An equal or older build must be rejected.")
    } catch let error as AppUpdateError { #expect(error == .notNewer) }
    #expect(await transport.requests.isEmpty)
  }

  private func releaseData(
    tag: String = "1.13.0-100", imageName: String = "Aurelia-1.13.0-100-macOS-universal.dmg",
    checksumName: String = "SHA256SUMS",
    imageURL: String = "https://api.github.com/repos/owner/repo/releases/assets/1"
  ) -> Data {
    try! JSONSerialization.data(withJSONObject: [
      "tag_name": tag, "draft": false,
      "assets": [
        ["name": imageName, "url": imageURL],
        ["name": checksumName, "url": "https://api.github.com/repos/owner/repo/releases/assets/2"],
      ],
    ])
  }

  private func checksums() -> Data {
    Data(
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  Aurelia-1.13.0-100-macOS-universal.dmg\n"
        .utf8)
  }

  private func response(
    status: Int = 200, type: String = "application/octet-stream", length: Int? = nil
  ) -> HTTPURLResponse {
    var fields = ["Content-Type": type]
    if let length { fields["Content-Length"] = String(length) }
    return HTTPURLResponse(
      url: URL(string: "https://api.github.com/repos/owner/repo/releases/assets/1")!,
      statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!
  }

  private func testFolder() throws -> URL {
    let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent(
        "Aurelia/TestRuns/update-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}

private actor StubUpdateTransport: AppUpdateTransport {
  enum Step: Sendable {
    case body(Data)
    case partialFailure(AppUpdateError)
  }
  private var steps: [Step]
  private(set) var requests: [URLRequest] = []

  init(steps: [Step]) { self.steps = steps }

  func transfer(_ request: URLRequest, maximumBytes: Int64, destination: URL?) async throws
    -> AppUpdateTransfer
  {
    requests.append(request)
    guard !steps.isEmpty else { throw AppUpdateError.invalidResponse }
    let step = steps.removeFirst()
    switch step {
    case .partialFailure(let failure):
      if let destination { try Data("partial".utf8).write(to: destination) }
      throw failure
    case .body(let data):
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Length": String(data.count)])!
      var accumulator = try AppUpdateTransferAccumulator(
        response: response, maximumBytes: maximumBytes,
        write: destination.map { url in { try $0.write(to: url, options: .withoutOverwriting) } })
      try accumulator.consume(data)
      return try accumulator.finish()
    }
  }
}
