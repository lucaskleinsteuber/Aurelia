import CryptoKit
import Foundation
import Testing

@testable import Aurelia

struct AppUpdateLogicTests {
  @Test func cachedNewReleaseRemainsAvailableAfter304() async throws {
    let transport = StubUpdateTransport(steps: [
      .tagged(releaseData(), "release-100"), .partialFailure(.notModified),
    ])
    let client = AppUpdateClient(transport: transport)
    let first = try await client.catalog(repository: "owner/repo", token: nil, cached: nil)
    let second = try await client.catalog(repository: "owner/repo", token: nil, cached: first.cache)
    #expect(second.release == first.release)
    #expect(AppUpdateLogic.isNewer(second.release, version: "1.12.0", build: 99))
    #expect(
      await transport.requests.last?.value(forHTTPHeaderField: "If-None-Match") == "release-100")
    #expect(!AppUpdateLogic.isNewer(second.release, version: "1.14.0", build: 99))
  }

  @Test func unexpected304WithoutCacheRetriesUnconditionally() async throws {
    let transport = StubUpdateTransport(steps: [
      .partialFailure(.notModified), .body(releaseData()),
    ])
    let result = try await AppUpdateClient(transport: transport).catalog(
      repository: "owner/repo", token: nil, cached: nil)
    #expect(result.release.build == 100)
    #expect(await transport.requests.count == 2)
    #expect(
      await transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "If-None-Match") == nil })
  }

  @Test func cachedBodiesAndCheckTimesAreValidatedAndSeparatedByFeed() throws {
    try withPreferences { defaults, _ in
      let cached = AppUpdateCatalogCache(data: releaseData(), etag: "release-100")
      AppUpdateCatalogCache.save(cached, repository: "owner/repo", defaults: defaults)
      #expect(
        AppUpdateCatalogCache.load(repository: "owner/repo", defaults: defaults)?.etag
          == cached.etag)
      AppUpdateCatalogCache.save(
        cached, repository: AppUpdateSource.publicTestRepository, defaults: defaults)
      #expect(
        AppUpdateCatalogCache.load(
          repository: AppUpdateSource.publicTestRepository, defaults: defaults) == nil)
      defaults.set(true, forKey: AppUpdateSource.publicTestKey)
      #expect(
        AppUpdateSource.repository(standard: "owner/repo", defaults: defaults)
          == AppUpdateSource.publicTestRepository)
      defaults.set(false, forKey: AppUpdateSource.publicTestKey)
      #expect(
        AppUpdateSource.repository(standard: "owner/repo", defaults: defaults) == "owner/repo")
      defaults.set(Date(), forKey: AppUpdatePreferences.checkKey("owner/repo"))
      #expect(!AppUpdatePreferences.backgroundCheckIsDue(in: defaults, repository: "owner/repo"))
      #expect(
        AppUpdatePreferences.backgroundCheckIsDue(
          in: defaults, repository: AppUpdateSource.publicTestRepository))
    }
  }

  @Test func publicFeedRequestsHaveNoAuthorizationAndRejectAToken() async throws {
    let data = releaseData(repository: AppUpdateSource.publicTestRepository)
    let transport = StubUpdateTransport(steps: [.body(data)])
    let client = AppUpdateClient(transport: transport)
    _ = try await client.catalog(
      repository: AppUpdateSource.publicTestRepository, token: nil, cached: nil)
    #expect(
      await transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    await #expect(throws: AppUpdateError.invalidURL) {
      try await client.catalog(
        repository: AppUpdateSource.publicTestRepository, token: "synthetic-never-sent", cached: nil
      )
    }
    #expect(await transport.requests.count == 1)
  }

  @Test func publicTestDoesNotEvenReadTheSavedToken() throws {
    try withPreferences { defaults, _ in
      var reads = 0
      let load = {
        reads += 1
        return "synthetic-token" as String?
      }
      defaults.set(true, forKey: AppUpdateSource.publicTestKey)
      #expect(AppUpdateSource.token(defaults: defaults, load: load) == nil)
      #expect(reads == 0)
      defaults.set(false, forKey: AppUpdateSource.publicTestKey)
      #expect(AppUpdateSource.token(defaults: defaults, load: load) == "synthetic-token")
      #expect(reads == 1)
    }
  }

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
      \(hash.uppercased())  ./Aurelia-1.12.1-99-macOS-arm64.dmg
      """
    #expect(AppUpdateLogic.checksum(for: "Aurelia-1.12.1-99-macOS-arm64.dmg", in: sums) == hash)
    #expect(AppUpdateLogic.checksum(for: "Missing.dmg", in: sums) == nil)
  }

  @Test
  func assetsUseTheAPIAddressThatWorksForPrivateRepositoriesToo() throws {
    let both = """
      {"tag_name":"1.25.1-116","assets":[
        {"name":"Aurelia-1.25.1-116-macOS-arm64.dmg","url":"https://api.github.com/repos/owner/repo/releases/assets/7",
         "browser_download_url":"https://github.com/owner/repo/releases/download/1.25.1-116/Aurelia-1.25.1-116-macOS-arm64.dmg"},
        {"name":"SHA256SUMS","url":"https://api.github.com/repos/owner/repo/releases/assets/8",
         "browser_download_url":"https://github.com/owner/repo/releases/download/1.25.1-116/SHA256SUMS"}]}
      """
    let parsed = try AppUpdateLogic.validatedRelease(
      fromLatest: Data(both.utf8), repository: "owner/repo")
    #expect(parsed.diskImageURL.host == "api.github.com")
    #expect(parsed.checksumsURL.host == "api.github.com")

    let publicOnly = both.replacingOccurrences(
      of: #""url":"https://api.github.com/repos/owner/repo/releases/assets/7","#, with: "")
    let fallback = try AppUpdateLogic.validatedRelease(
      fromLatest: Data(publicOnly.utf8), repository: "owner/repo")
    #expect(fallback.diskImageURL.host == "github.com")
  }

  @Test
  func theLatestReleaseNeedsItsDiskImageAndChecksums() throws {
    let release = """
      {"tag_name":"1.13.0-100","draft":false,"html_url":"https://github.com/owner/repo/releases/tag/1.13.0-100",
       "assets":[
        {"name":"Aurelia-1.13.0-100-macOS-arm64.dmg","url":"https://api.github.com/repos/owner/repo/releases/assets/1"},
        {"name":"SHA256SUMS","url":"https://api.github.com/repos/owner/repo/releases/assets/2"}]}
      """
    let parsed = try #require(AppUpdateLogic.release(fromLatest: Data(release.utf8)))
    #expect(parsed.version == "1.13.0")
    #expect(parsed.build == 100)
    #expect(parsed.diskImageURL.absoluteString.hasSuffix("/assets/1"))
    #expect(parsed.checksumsURL.absoluteString.hasSuffix("/assets/2"))
    let withoutImage = release.replacingOccurrences(of: "macOS-arm64.dmg", with: "other.dmg")
    #expect(AppUpdateLogic.release(fromLatest: Data(withoutImage.utf8)) == nil)
    #expect(AppUpdateLogic.isRepository("lucasfd3/Aurelia"))
    #expect(!AppUpdateLogic.isRepository("https://github.com/x/y"))
    #expect(!AppUpdateLogic.isRepository("x/y/z"))
  }

  @Test
  func publicAssetURLsRequireMatchingRepository() {
    let valid = URL(
      string: "https://github.com/owner/repo/releases/download/1.20.0-110/Aurelia-1.20.0-110.dmg")!
    #expect(AppUpdateLogic.isPublicAssetURL(valid, repository: "owner/repo"))
    #expect(AppUpdateLogic.isPublicAssetURL(valid, repository: nil))
    #expect(!AppUpdateLogic.isPublicAssetURL(valid, repository: "other/repo"))

    let wrongHost = URL(
      string: "https://evil.github.com/owner/repo/releases/download/1.20.0-110/Aurelia.dmg")!
    #expect(!AppUpdateLogic.isPublicAssetURL(wrongHost, repository: "owner/repo"))

    let http = URL(
      string: "http://github.com/owner/repo/releases/download/1.20.0-110/Aurelia.dmg")!
    #expect(!AppUpdateLogic.isPublicAssetURL(http, repository: "owner/repo"))

    let wrongPath = URL(
      string: "https://github.com/owner/repo/releases/1.20.0-110/Aurelia.dmg")!
    #expect(!AppUpdateLogic.isPublicAssetURL(wrongPath, repository: "owner/repo"))

    let queryParam = URL(
      string: "https://github.com/owner/repo/releases/download/1.20.0-110/Aurelia.dmg?token=123")!
    #expect(!AppUpdateLogic.isPublicAssetURL(queryParam, repository: "owner/repo"))
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

  @Test func publicRepositoryUpdateChecksAndDownloadsOmitAuthorizationHeader() async throws {
    let folder = try testFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let transport = StubUpdateTransport(steps: [
      .body(releaseData()), .body(checksums()), .body(Data("abc".utf8)),
    ])
    let client = AppUpdateClient(transport: transport)
    let release = try await client.latest(repository: "owner/repo")
    let image = try await client.download(
      release, repository: "owner/repo", currentBuild: 99, folder: folder)
    #expect(try Data(contentsOf: image) == Data("abc".utf8))
    let requests = await transport.requests
    #expect(requests.count == 3)
    for request in requests {
      #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }
  }

  @Test func releaseNotesAndDownloadSizeComeFromTheMatchingImage() throws {
    let notes = "## Changes\n\n- Keeps **Markdown** as plain text.\n<https://example.invalid>"
    var object = try #require(
      JSONSerialization.jsonObject(with: releaseData(notes: notes, imageSize: Int64(147_000_000)))
        as? [String: Any])
    var assets = try #require(object["assets"] as? [[String: Any]])
    assets.insert(["name": "Other.dmg", "size": 1], at: 0)
    object["assets"] = assets
    let release = try AppUpdateLogic.validatedRelease(
      fromLatest: JSONSerialization.data(withJSONObject: object))
    #expect(release.releaseNotes == notes)
    #expect(release.downloadBytes == 147_000_000)
    #expect(AppUpdateLogic.releaseNotesText(release.releaseNotes) == notes)
    #expect(AppUpdateLogic.downloadSizeText(release.downloadBytes).hasPrefix("Download size: "))
    let missing = try AppUpdateLogic.validatedRelease(fromLatest: releaseData())
    #expect(missing.releaseNotes.isEmpty)
    #expect(missing.downloadBytes == nil)
    #expect(
      AppUpdateLogic.releaseNotesText(" \n\t") == "No release notes were provided for this version."
    )
    #expect(AppUpdateLogic.downloadSizeText(nil) == "Download size unavailable.")
  }

  @Test(arguments: [Int64(0), 1, 147_000_000, Int64.max])
  func downloadSizesAcceptNonnegativeIntegerByteCounts(bytes: Int64) throws {
    let release = try AppUpdateLogic.validatedRelease(fromLatest: releaseData(imageSize: bytes))
    #expect(release.downloadBytes == bytes)
  }

  @Test func malformedOptionalReleaseDetailsDoNotInventASizeOrNotes() throws {
    for size: Any in [true, false, -1, 1.5, "147000000", NSNull(), Double.greatestFiniteMagnitude] {
      let release = try AppUpdateLogic.validatedRelease(
        fromLatest: releaseData(notes: 42, imageSize: size))
      #expect(release.downloadBytes == nil)
      #expect(release.releaseNotes.isEmpty)
    }
  }

  @Test func automaticChecksDefaultOnAndRunAtMostOncePerDay() throws {
    try withPreferences { defaults, _ in
      let now = Date(timeIntervalSince1970: 1_800_000_000)
      #expect(AppUpdatePreferences.checksAutomatically(in: defaults))
      #expect(AppUpdatePreferences.backgroundCheckIsDue(in: defaults, now: now))
      defaults.set(now, forKey: AppUpdatePreferences.lastCheckKey)
      #expect(!AppUpdatePreferences.backgroundCheckIsDue(in: defaults, now: now))
      #expect(
        !AppUpdatePreferences.backgroundCheckIsDue(
          in: defaults, now: now.addingTimeInterval(86_399)))
      #expect(
        AppUpdatePreferences.backgroundCheckIsDue(in: defaults, now: now.addingTimeInterval(86_400))
      )
      defaults.set(false, forKey: AppUpdatePreferences.automaticChecksKey)
      #expect(!AppUpdatePreferences.checksAutomatically(in: defaults))
      #expect(
        !AppUpdatePreferences.backgroundCheckIsDue(
          in: defaults, now: now.addingTimeInterval(172_800)))
      defaults.set(true, forKey: AppUpdatePreferences.automaticChecksKey)
      #expect(
        AppUpdatePreferences.backgroundCheckIsDue(
          in: defaults, now: now.addingTimeInterval(172_800)))
    }
  }

  @Test func skippedVersionsPersistWithoutSuppressingOtherVersionsOrManualChecks() throws {
    try withPreferences { defaults, suite in
      AppUpdatePreferences.skip(version: "1.15.0", in: defaults)
      AppUpdatePreferences.skip(version: "1.15.0", in: defaults)
      AppUpdatePreferences.skip(version: "1.14.1", in: defaults)
      let reopened = try #require(UserDefaults(suiteName: suite))
      #expect(
        reopened.stringArray(forKey: AppUpdatePreferences.skippedVersionsKey) == [
          "1.15.0", "1.14.1",
        ])
      #expect(
        !AppUpdatePreferences.shouldOffer(
          version: "1.15.0", userInitiated: false, defaults: reopened))
      #expect(
        !AppUpdatePreferences.shouldOffer(
          version: "1.14.1", userInitiated: false, defaults: reopened))
      #expect(
        AppUpdatePreferences.shouldOffer(
          version: "1.15.1", userInitiated: false, defaults: reopened))
      #expect(
        AppUpdatePreferences.shouldOffer(
          version: "1.16.0", userInitiated: false, defaults: reopened))
      #expect(
        AppUpdatePreferences.shouldOffer(version: "1.15.0", userInitiated: true, defaults: reopened)
      )
    }
  }

  @Test func choicesAreRecheckedWhenAnInFlightBackgroundCheckCompletes() throws {
    try withPreferences { defaults, _ in
      #expect(
        AppUpdatePreferences.shouldOffer(
          version: "1.15.0", userInitiated: false, defaults: defaults))
      defaults.set(false, forKey: AppUpdatePreferences.automaticChecksKey)
      #expect(
        !AppUpdatePreferences.shouldOffer(
          version: "1.15.0", userInitiated: false, defaults: defaults))
      #expect(
        AppUpdatePreferences.shouldOffer(version: "1.15.0", userInitiated: true, defaults: defaults)
      )
      defaults.set(true, forKey: AppUpdatePreferences.automaticChecksKey)
      AppUpdatePreferences.skip(version: "1.15.0", in: defaults)
      #expect(
        !AppUpdatePreferences.shouldOffer(
          version: "1.15.0", userInitiated: false, defaults: defaults))
      #expect(
        AppUpdatePreferences.shouldOffer(version: "1.15.0", userInitiated: true, defaults: defaults)
      )
    }
  }

  private func withPreferences(_ check: (UserDefaults, String) throws -> Void) throws {
    let suite = "Aurelia.UpdateTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try check(defaults, suite)
  }

  private func releaseData(
    tag: String = "1.13.0-100", imageName: String = "Aurelia-1.13.0-100-macOS-arm64.dmg",
    checksumName: String = "SHA256SUMS",
    imageURL: String = "https://api.github.com/repos/owner/repo/releases/assets/1",
    notes: Any? = nil, imageSize: Any? = nil, repository: String = "owner/repo"
  ) -> Data {
    var image: [String: Any] = [
      "name": imageName, "url": imageURL.replacingOccurrences(of: "owner/repo", with: repository),
    ]
    if let imageSize { image["size"] = imageSize }
    var release: [String: Any] = [
      "tag_name": tag, "draft": false,
      "assets": [
        image,
        [
          "name": checksumName,
          "url": "https://api.github.com/repos/\(repository)/releases/assets/2",
        ],
      ],
    ]
    if let notes { release["body"] = notes }
    return try! JSONSerialization.data(withJSONObject: release)
  }

  private func checksums() -> Data {
    Data(
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  Aurelia-1.13.0-100-macOS-arm64.dmg\n"
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
    case tagged(Data, String)
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
    case .body(let data), .tagged(let data, _):
      var headers = ["Content-Length": String(data.count)]
      if case .tagged(_, let etag) = step { headers["ETag"] = etag }
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: headers)!
      var accumulator = try AppUpdateTransferAccumulator(
        response: response, maximumBytes: maximumBytes,
        write: destination.map { url in { try $0.write(to: url, options: .withoutOverwriting) } })
      try accumulator.consume(data)
      return try accumulator.finish()
    }
  }
}

final class FakeGitHubURLProtocol: URLProtocol, @unchecked Sendable {
  enum Action: Sendable {
    case respond(status: Int, headers: [String: String], body: Data?)
    case redirect(to: URL, status: Int)
    case cutOff(status: Int, headers: [String: String], partialBody: Data, error: Error)
    case fail(Error)
  }

  static let lock = NSLock()
  nonisolated(unsafe) static var responder: (@Sendable (URLRequest) -> Action)?
  nonisolated(unsafe) static var recordedRequests: [URLRequest] = []

  static func configure(_ responder: @escaping @Sendable (URLRequest) -> Action) {
    lock.lock()
    defer { lock.unlock() }
    self.responder = responder
    recordedRequests = []
  }

  static func requests() -> [URLRequest] {
    lock.lock()
    defer { lock.unlock() }
    return recordedRequests
  }

  override class func canInit(with request: URLRequest) -> Bool {
    guard let host = request.url?.host?.lowercased() else { return false }
    return host == "api.github.com" || host == "objects.githubusercontent.com"
      || host == "github.com"
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    Self.lock.lock()
    Self.recordedRequests.append(request)
    let currentResponder = Self.responder
    Self.lock.unlock()

    guard let currentResponder else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }

    switch currentResponder(request) {
    case .respond(let status, let headers, let body):
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      if let body { client?.urlProtocol(self, didLoad: body) }
      client?.urlProtocolDidFinishLoading(self)

    case .redirect(let to, let status):
      let headers = ["Location": to.absoluteString]
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
      var nextRequest = URLRequest(url: to)
      nextRequest.allHTTPHeaderFields = request.allHTTPHeaderFields
      client?.urlProtocol(self, wasRedirectedTo: nextRequest, redirectResponse: response)

    case .cutOff(let status, let headers, let partialBody, let error):
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: partialBody)
      client?.urlProtocol(self, didFailWithError: error)

    case .fail(let error):
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

@Suite(.serialized)
struct AppUpdateFakeGitHubHarnessTests {
  private func makeClient() -> AppUpdateClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FakeGitHubURLProtocol.self]
    return AppUpdateClient(transport: AppUpdateURLSessionTransport(sessionConfiguration: config))
  }

  private func testRunFolder() throws -> URL {
    let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent(
        "Aurelia/TestRuns/fake-github-harness-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  @Test
  func harnessSimulatesFullReleaseLifecycleWithRedirectAndRemovesAuthorizationOnRedirect()
    async throws
  {
    let folder = try testRunFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let client = makeClient()
    let syntheticDmgData = Data("synthetic-arm64-macos-dmg-content-109".utf8)
    let syntheticDigest = SHA256.hash(data: syntheticDmgData).map { String(format: "%02x", $0) }
      .joined()

    let releaseJson = """
      {
        "tag_name": "1.19.0-109",
        "draft": false,
        "html_url": "https://github.com/owner/repo/releases/tag/1.19.0-109",
        "assets": [
          {
            "name": "Aurelia-1.19.0-109-macOS-arm64.dmg",
            "url": "https://api.github.com/repos/owner/repo/releases/assets/101",
            "size": \(syntheticDmgData.count)
          },
          {
            "name": "SHA256SUMS",
            "url": "https://api.github.com/repos/owner/repo/releases/assets/102"
          }
        ]
      }
      """
    let sumsText = "\(syntheticDigest)  Aurelia-1.19.0-109-macOS-arm64.dmg\n"

    FakeGitHubURLProtocol.configure { req in
      let path = req.url?.path ?? ""
      let host = req.url?.host ?? ""

      if host == "api.github.com" && path.hasSuffix("/releases/latest") {
        return .respond(
          status: 200,
          headers: ["Content-Type": "application/json", "Content-Length": "\(releaseJson.count)"],
          body: Data(releaseJson.utf8))
      }

      if host == "api.github.com" && path.hasSuffix("/assets/102") {
        return .respond(
          status: 200,
          headers: [
            "Content-Type": "application/octet-stream", "Content-Length": "\(sumsText.count)",
          ],
          body: Data(sumsText.utf8))
      }

      if host == "api.github.com" && path.hasSuffix("/assets/101") {
        return .redirect(
          to: URL(
            string:
              "https://objects.githubusercontent.com/github-production-release-asset/Aurelia-1.19.0-109.dmg"
          )!, status: 302)
      }

      if host == "objects.githubusercontent.com" {
        return .respond(
          status: 200,
          headers: [
            "Content-Type": "application/octet-stream",
            "Content-Length": "\(syntheticDmgData.count)",
          ],
          body: syntheticDmgData)
      }

      return .respond(status: 404, headers: [:], body: nil)
    }

    let release = try await client.latest(
      repository: "owner/repo", token: "synthetic-secret-token")
    #expect(release.version == "1.19.0")
    #expect(release.build == 109)

    let destination = try await client.download(
      release, repository: "owner/repo", token: "synthetic-secret-token", currentBuild: 108,
      folder: folder)

    #expect(FileManager.default.fileExists(atPath: destination.path))
    #expect(try Data(contentsOf: destination) == syntheticDmgData)

    let requests = FakeGitHubURLProtocol.requests()
    #expect(requests.count == 4)

    // Initial requests to api.github.com carry Authorization
    let apiRequests = requests.filter { $0.url?.host == "api.github.com" }
    #expect(!apiRequests.isEmpty)
    for req in apiRequests {
      #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-secret-token")
    }

    // The redirected request to objects.githubusercontent.com must NEVER carry Authorization or Cookie
    let redirectRequests = requests.filter { $0.url?.host == "objects.githubusercontent.com" }
    #expect(redirectRequests.count == 1)
    for req in redirectRequests {
      #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
      #expect(req.value(forHTTPHeaderField: "Cookie") == nil)
      #expect(req.value(forHTTPHeaderField: "Proxy-Authorization") == nil)
    }
  }

  @Test
  func harnessEnforcesSha256BeforeStartingHelperAndDeletesCorruptImage() async throws {
    let folder = try testRunFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let client = makeClient()
    let tamperedDmgData = Data("tampered-content".utf8)
    let legitimateDigest = String(repeating: "f", count: 64)

    let releaseJson = """
      {
        "tag_name": "1.19.0-109",
        "draft": false,
        "assets": [
          {
            "name": "Aurelia-1.19.0-109-macOS-arm64.dmg",
            "url": "https://api.github.com/repos/owner/repo/releases/assets/201"
          },
          {
            "name": "SHA256SUMS",
            "url": "https://api.github.com/repos/owner/repo/releases/assets/202"
          }
        ]
      }
      """
    let sumsText = "\(legitimateDigest)  Aurelia-1.19.0-109-macOS-arm64.dmg\n"

    FakeGitHubURLProtocol.configure { req in
      let path = req.url?.path ?? ""
      let host = req.url?.host ?? ""

      if host == "api.github.com" && path.hasSuffix("/releases/latest") {
        return .respond(
          status: 200, headers: ["Content-Type": "application/json"], body: Data(releaseJson.utf8))
      }
      if host == "api.github.com" && path.hasSuffix("/assets/202") {
        return .respond(
          status: 200, headers: ["Content-Type": "application/octet-stream"],
          body: Data(sumsText.utf8))
      }
      if host == "api.github.com" && path.hasSuffix("/assets/201") {
        return .redirect(
          to: URL(string: "https://objects.githubusercontent.com/download/dmg")!, status: 302)
      }
      if host == "objects.githubusercontent.com" {
        return .respond(
          status: 200,
          headers: [
            "Content-Type": "application/octet-stream",
            "Content-Length": "\(tamperedDmgData.count)",
          ],
          body: tamperedDmgData)
      }
      return .respond(status: 404, headers: [:], body: nil)
    }

    let release = try await client.latest(repository: "owner/repo")
    do {
      _ = try await client.download(
        release, repository: "owner/repo", currentBuild: 108, folder: folder)
      Issue.record("A corrupted download must fail before starting helper.")
    } catch let error as AppUpdateError {
      #expect(error == .checksumMismatch)
    }

    // Verify partial or corrupt file was removed
    let remaining = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    #expect(remaining.isEmpty)
  }

  @Test
  func harnessRemovesPartialDownloadsOnCutOffConnection() async throws {
    let folder = try testRunFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let client = makeClient()
    let releaseJson = """
      {
        "tag_name": "1.19.0-109",
        "draft": false,
        "assets": [
          {
            "name": "Aurelia-1.19.0-109-macOS-arm64.dmg",
            "url": "https://api.github.com/repos/owner/repo/releases/assets/301"
          },
          {
            "name": "SHA256SUMS",
            "url": "https://api.github.com/repos/owner/repo/releases/assets/302"
          }
        ]
      }
      """
    let sumsText =
      "\(String(repeating: "a", count: 64))  Aurelia-1.19.0-109-macOS-arm64.dmg\n"

    FakeGitHubURLProtocol.configure { req in
      let path = req.url?.path ?? ""
      let host = req.url?.host ?? ""

      if host == "api.github.com" && path.hasSuffix("/releases/latest") {
        return .respond(
          status: 200, headers: ["Content-Type": "application/json"], body: Data(releaseJson.utf8))
      }
      if host == "api.github.com" && path.hasSuffix("/assets/302") {
        return .respond(
          status: 200, headers: ["Content-Type": "application/octet-stream"],
          body: Data(sumsText.utf8))
      }
      if host == "api.github.com" && path.hasSuffix("/assets/301") {
        return .redirect(
          to: URL(string: "https://objects.githubusercontent.com/download/cutoff")!, status: 302)
      }
      if host == "objects.githubusercontent.com" {
        // Cut-off: reports 10,000 bytes expected, sends only 100 bytes, then disconnects
        return .cutOff(
          status: 200,
          headers: ["Content-Type": "application/octet-stream", "Content-Length": "10000"],
          partialBody: Data(repeating: 0x41, count: 100),
          error: URLError(.networkConnectionLost))
      }
      return .respond(status: 404, headers: [:], body: nil)
    }

    let release = try await client.latest(repository: "owner/repo")
    do {
      _ = try await client.download(
        release, repository: "owner/repo", currentBuild: 108, folder: folder)
      Issue.record("A cut-off download must fail.")
    } catch let error as AppUpdateError {
      #expect(error == .connectionLost || error == .incompleteDownload)
    }

    // Partial file must be deleted
    let remaining = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    #expect(remaining.isEmpty)
  }

  @Test
  func harnessRejectsHtmlErrorPageWithInvalidResponse() async throws {
    let client = makeClient()
    let htmlError = "<!DOCTYPE html><html><body>Error 404 Not Found</body></html>"

    FakeGitHubURLProtocol.configure { _ in
      .respond(
        status: 200,
        headers: ["Content-Type": "text/html; charset=utf-8"],
        body: Data(htmlError.utf8))
    }

    do {
      _ = try await client.latest(repository: "owner/repo")
      Issue.record("HTML responses must be rejected as invalid.")
    } catch let error as AppUpdateError {
      #expect(error == .invalidResponse)
    }
  }

  @Test(arguments: [401, 500, 502, 503])
  func harnessClassifiesGenericHttpErrors(statusCode: Int) async throws {
    let client = makeClient()

    FakeGitHubURLProtocol.configure { _ in
      .respond(
        status: statusCode,
        headers: ["Content-Type": "application/json"],
        body: Data("{\"message\": \"error\"}".utf8))
    }

    do {
      _ = try await client.latest(repository: "owner/repo")
      Issue.record("HTTP error \(statusCode) must fail.")
    } catch let error as AppUpdateError {
      #expect(error == .github(statusCode))
    }
  }

  @Test
  func harnessClassifiesRateLimitingViaStatus429AndHeaderOn403() async throws {
    let client = makeClient()

    // 429 Too Many Requests
    FakeGitHubURLProtocol.configure { _ in
      .respond(
        status: 429,
        headers: ["Content-Type": "application/json"],
        body: Data("{\"message\": \"rate limited\"}".utf8))
    }
    do {
      _ = try await client.latest(repository: "owner/repo")
      Issue.record("429 must throw rateLimited")
    } catch let error as AppUpdateError {
      #expect(error == .rateLimited)
    }

    // 403 with x-ratelimit-remaining: 0
    FakeGitHubURLProtocol.configure { _ in
      .respond(
        status: 403,
        headers: [
          "Content-Type": "application/json",
          "x-ratelimit-remaining": "0",
        ],
        body: Data("{\"message\": \"rate limit exceeded\"}".utf8))
    }
    do {
      _ = try await client.latest(repository: "owner/repo")
      Issue.record("403 with 0 remaining must throw rateLimited")
    } catch let error as AppUpdateError {
      #expect(error == .rateLimited)
    }

    // 403 with positive remaining quota is a normal github error
    FakeGitHubURLProtocol.configure { _ in
      .respond(
        status: 403,
        headers: [
          "Content-Type": "application/json",
          "x-ratelimit-remaining": "42",
        ],
        body: Data("{\"message\": \"forbidden\"}".utf8))
    }
    do {
      _ = try await client.latest(repository: "owner/repo")
      Issue.record("403 with remaining quota must throw github(403)")
    } catch let error as AppUpdateError {
      #expect(error == .github(403))
    }
  }

  @Test
  func harnessClassifies404AsPrivateRepositoryWhenAnonymousAndGithub404WhenTokenPresent()
    async throws
  {
    let client = makeClient()

    FakeGitHubURLProtocol.configure { _ in
      .respond(
        status: 404,
        headers: ["Content-Type": "application/json"],
        body: Data("{\"message\": \"Not Found\"}".utf8))
    }

    // Anonymous check gets privateRepository
    do {
      _ = try await client.latest(repository: "owner/repo", token: nil)
      Issue.record("Anonymous 404 must throw privateRepository")
    } catch let error as AppUpdateError {
      #expect(error == .privateRepository)
    }

    // Token-bearing check gets github(404)
    do {
      _ = try await client.latest(repository: "owner/repo", token: "synthetic-token")
      Issue.record("Token-bearing 404 must throw github(404)")
    } catch let error as AppUpdateError {
      #expect(error == .github(404))
    }
  }

  @Test
  func harnessHonorsETag304NotModified() async throws {
    let client = makeClient()

    FakeGitHubURLProtocol.configure { req in
      #expect(req.value(forHTTPHeaderField: "If-None-Match") == "W/\"etag-abc\"")
      return .respond(status: 304, headers: [:], body: nil)
    }

    do {
      _ = try await client.latest(
        repository: "owner/repo", token: nil, ifNoneMatch: "W/\"etag-abc\"")
      Issue.record("304 must throw notModified")
    } catch let error as AppUpdateError {
      #expect(error == .notModified)
    }
  }

  @Test
  func harnessSimulatesAnonymousReleaseLifecycleWithBrowserDownloadUrl() async throws {
    let folder = try testRunFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let client = makeClient()
    let syntheticDmgData = Data("synthetic-arm64-macos-dmg-content-110".utf8)
    let syntheticDigest = SHA256.hash(data: syntheticDmgData).map { String(format: "%02x", $0) }
      .joined()

    let releaseJson = """
      {
        "tag_name": "1.20.0-110",
        "draft": false,
        "html_url": "https://github.com/owner/repo/releases/tag/1.20.0-110",
        "assets": [
          {
            "name": "Aurelia-1.20.0-110-macOS-arm64.dmg",
            "browser_download_url": "https://github.com/owner/repo/releases/download/1.20.0-110/Aurelia-1.20.0-110-macOS-arm64.dmg",
            "url": "https://api.github.com/repos/owner/repo/releases/assets/501",
            "size": \(syntheticDmgData.count)
          },
          {
            "name": "SHA256SUMS",
            "browser_download_url": "https://github.com/owner/repo/releases/download/1.20.0-110/SHA256SUMS",
            "url": "https://api.github.com/repos/owner/repo/releases/assets/502"
          }
        ]
      }
      """
    let sumsText = "\(syntheticDigest)  Aurelia-1.20.0-110-macOS-arm64.dmg\n"

    FakeGitHubURLProtocol.configure { req in
      let path = req.url?.path ?? ""
      let host = req.url?.host ?? ""

      if host == "api.github.com" && path.hasSuffix("/releases/latest") {
        return .respond(
          status: 200,
          headers: [
            "Content-Type": "application/json",
            "Content-Length": "\(releaseJson.count)",
            "ETag": "W/\"etag-release-110\"",
          ],
          body: Data(releaseJson.utf8))
      }

      if host == "api.github.com" && path.hasSuffix("/releases/assets/502") {
        return .respond(
          status: 200,
          headers: [
            "Content-Type": "application/octet-stream",
            "Content-Length": "\(sumsText.count)",
          ],
          body: Data(sumsText.utf8))
      }

      if host == "api.github.com" && path.hasSuffix("/releases/assets/501") {
        return .redirect(
          to: URL(
            string:
              "https://objects.githubusercontent.com/github-production-release-asset/Aurelia-1.20.0-110.dmg"
          )!, status: 302)
      }

      if host == "objects.githubusercontent.com" {
        return .respond(
          status: 200,
          headers: [
            "Content-Type": "application/octet-stream",
            "Content-Length": "\(syntheticDmgData.count)",
          ],
          body: syntheticDmgData)
      }

      return .respond(status: 404, headers: [:], body: nil)
    }

    let (release, etag) = try await client.latestRelease(
      repository: "owner/repo", token: nil)
    #expect(release.version == "1.20.0")
    #expect(release.build == 110)
    #expect(etag == "W/\"etag-release-110\"")
    #expect(
      release.diskImageURL.absoluteString
        == "https://api.github.com/repos/owner/repo/releases/assets/501")

    let destination = try await client.download(
      release, repository: "owner/repo", token: nil, currentBuild: 109, folder: folder)

    #expect(FileManager.default.fileExists(atPath: destination.path))
    #expect(try Data(contentsOf: destination) == syntheticDmgData)

    let recorded = FakeGitHubURLProtocol.requests()
    // Verify that NO request carried an Authorization header
    for req in recorded {
      #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    }
  }

  @Test
  func harnessNeverOffersOrDownloadsOlderOrEqualBuild() async throws {
    let client = makeClient()
    let releaseJson = """
      {
        "tag_name": "1.18.0-108",
        "draft": false,
        "assets": [
          {
            "name": "Aurelia-1.18.0-108-macOS-arm64.dmg",
            "url": "https://api.github.com/repos/owner/repo/releases/assets/501"
          },
          {
            "name": "SHA256SUMS",
            "url": "https://api.github.com/repos/owner/repo/releases/assets/502"
          }
        ]
      }
      """

    FakeGitHubURLProtocol.configure { req in
      let path = req.url?.path ?? ""
      if path.hasSuffix("/releases/latest") {
        return .respond(
          status: 200, headers: ["Content-Type": "application/json"], body: Data(releaseJson.utf8))
      }
      Issue.record("Download assets should never be requested for an older/equal release.")
      return .respond(status: 404, headers: [:], body: nil)
    }

    let release = try await client.latest(repository: "owner/repo")
    #expect(release.build == 108)

    // Equal build is rejected
    do {
      _ = try await client.download(
        release, repository: "owner/repo", currentBuild: 108,
        folder: URL(fileURLWithPath: "/tmp"))
      Issue.record("Equal build must not be downloaded.")
    } catch let error as AppUpdateError {
      #expect(error == .notNewer)
    }

    // Older build is rejected
    do {
      _ = try await client.download(
        release, repository: "owner/repo", currentBuild: 109,
        folder: URL(fileURLWithPath: "/tmp"))
      Issue.record("Older build must not be downloaded.")
    } catch let error as AppUpdateError {
      #expect(error == .notNewer)
    }
  }

  @Test
  func harnessValidatesSkipThisVersionAndAutomaticCheckSwitch() throws {
    let suite = "FakeGitHubHarnessTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    // Initial state: automatic checks enabled, version 1.19.0 not skipped
    #expect(AppUpdatePreferences.checksAutomatically(in: defaults))
    #expect(
      AppUpdatePreferences.shouldOffer(version: "1.19.0", userInitiated: false, defaults: defaults))

    // Skip version 1.19.0
    AppUpdatePreferences.skip(version: "1.19.0", in: defaults)
    #expect(
      !AppUpdatePreferences.shouldOffer(version: "1.19.0", userInitiated: false, defaults: defaults)
    )
    // Manual check still offers it
    #expect(
      AppUpdatePreferences.shouldOffer(version: "1.19.0", userInitiated: true, defaults: defaults))
    // Newer version 1.20.0 is still offered
    #expect(
      AppUpdatePreferences.shouldOffer(version: "1.20.0", userInitiated: false, defaults: defaults))

    // Disable automatic checks
    defaults.set(false, forKey: AppUpdatePreferences.automaticChecksKey)
    #expect(!AppUpdatePreferences.checksAutomatically(in: defaults))
    #expect(
      !AppUpdatePreferences.shouldOffer(version: "1.20.0", userInitiated: false, defaults: defaults)
    )
    #expect(
      AppUpdatePreferences.shouldOffer(version: "1.20.0", userInitiated: true, defaults: defaults))
  }
}
