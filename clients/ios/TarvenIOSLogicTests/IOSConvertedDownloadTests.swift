import Foundation
import Testing

/// Smaller downloads on iPhone and iPad ("converted-downloads-v1"): which quality a download
/// takes, which pieces it may ask for, and how a stopped download continues.
struct IOSConvertedDownloadTests {
  @Test @MainActor func backgroundExpirationCanArriveOnARealBackgroundQueue() async {
    var deliveredOnMainActor = false
    await withCheckedContinuation { continuation in
      let handler = IOSBackgroundTaskCallbacks.expiration {
        MainActor.assertIsolated()
        deliveredOnMainActor = Thread.isMainThread
        continuation.resume()
      }
      DispatchQueue.global(qos: .utility).async(execute: handler)
    }
    #expect(deliveredOnMainActor)
  }

  private func options(_ ids: [String], canConvert: Bool = true) -> IOSDownloadOptions {
    IOSDownloadOptions(
      originalBytes: 54_000_000_000, durationSeconds: 7200, canConvert: canConvert,
      qualities: ids.map {
        IOSDownloadQuality(
          id: $0, width: 0, height: 0, estimatedBytes: 1_800_000_000, estimatedSeconds: nil)
      },
      audioTracks: [], audioTrack: 1)
  }

  @Test func theSettingPicksTheQualityOrTheOriginal() {
    let all = options(["1080p", "720p", "480p", "360p"])
    #expect(IOSDownloadQualityPreference.resolve("ask", options: all) == .ask)
    #expect(IOSDownloadQualityPreference.resolve("720p", options: all) == .converted("720p"))
    #expect(
      IOSDownloadQualityPreference.resolve("1080p", options: options(["480p"]))
        == .converted("480p"))
    #expect(
      IOSDownloadQualityPreference.resolve("720p", options: options(["480p", "1080p", "720p"]))
        == .converted("720p"))
    for offered in [["720p", "1080p"], ["1080p", "720p"]] {
      #expect(
        IOSDownloadQualityPreference.resolve("480p", options: options(offered))
          == .converted("720p"))
    }
    #expect(IOSDownloadQualityPreference.resolve("ask", options: options([])) == .original)
    #expect(
      IOSDownloadQualityPreference.resolve("720p", options: options(["480p"], canConvert: false))
        == .original)
    #expect(IOSDownloadText.button(all.qualities[1]) == "720p · about 1.8 GB")
  }

  @Test func failedQualityRequestsNeverResolveToTheOriginal() async {
    for preference in ["ask", "720p"] {
      await #expect(throws: URLError(.cannotConnectToHost)) {
        try await IOSDownloadQualityPreference.resolve(preference) {
          throw URLError(.cannotConnectToHost)
        }
      }
    }
  }

  @Test func laterEpisodesUseAnAvailableSmallerQualityAndOnlyKnownEmptyOffersUseOriginal()
    async throws
  {
    let smaller = try await IOSDownloadQualityPreference.resolve("720p") {
      options(["480p"])
    }
    #expect(smaller.choice == .converted("480p"))
    #expect(smaller.options.qualities.first?.estimatedBytes == 1_800_000_000)
    let original = try await IOSDownloadQualityPreference.resolve("720p") { options([]) }
    #expect(original.choice == .original)
  }

  @Test func onlyTheServersHLSPiecesAreAskedFor() {
    #expect(IOSConvertedDownloadPlan.isValidPiece(quality: "720p", piece: "init.mp4"))
    #expect(IOSConvertedDownloadPlan.isValidPiece(quality: "1080p", piece: "1234.m4s"))
    #expect(!IOSConvertedDownloadPlan.isValidPiece(quality: "../x", piece: "init.mp4"))
    #expect(!IOSConvertedDownloadPlan.isValidPiece(quality: "720p", piece: "../../secret"))
    #expect(
      IOSConvertedDownloadPlan.segmentCount(
        playlist: "#EXTM3U\n#EXTINF:4,\n0.m4s?audio=1\n#EXTINF:2,\n1.m4s?audio=1\n") == 2)
    #expect(IOSConvertedDownloadPlan.retryDelay(status: 429, retryAfter: 5, attempt: 3) == 5)
    #expect(IOSConvertedDownloadPlan.retryDelay(status: 403, retryAfter: nil, attempt: 0) == nil)
  }

  @Test func aStoppedDownloadContinuesWhereItWasSavedOrStartsOver() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let partial = folder.appendingPathComponent("title.mp4.part")
    let initData = Data(repeating: 1, count: 10)

    var progress = IOSConvertedProgress(quality: "720p", audio: 1)
    try IOSConvertedDownloadPlan.prepare(partial, progress: &progress, initData: initData)
    #expect(progress.writtenBytes == 10 && progress.nextSegment == 0 && progress.initDigest != nil)

    // Two segments were saved, a third was half written when the app stopped.
    let handle = try FileHandle(forWritingTo: partial)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(repeating: 2, count: 40))
    try handle.close()
    progress.nextSegment = 2
    progress.writtenBytes = 30
    progress.segmentCount = 10
    #expect(progress.share == 0.2)
    try IOSConvertedDownloadPlan.prepare(partial, progress: &progress, initData: initData)
    #expect(try Data(contentsOf: partial).count == 30)
    #expect(progress.nextSegment == 2)

    // Another init (the server switched encoders): the copy starts over.
    try IOSConvertedDownloadPlan.prepare(
      partial, progress: &progress, initData: Data(repeating: 3, count: 12))
    #expect(progress.nextSegment == 0 && progress.writtenBytes == 12)
    #expect(try Data(contentsOf: partial) == Data(repeating: 3, count: 12))
  }

  @Test func aPendingConvertedDownloadShowsItsSegmentsAsProgress() throws {
    let json =
      #"{"quality":"480p","audio":null,"segmentCount":4,"nextSegment":1,"writtenBytes":100,"initDigest":"x"}"#
    let progress = try JSONDecoder().decode(IOSConvertedProgress.self, from: Data(json.utf8))
    #expect(progress.share == 0.25)
  }
}
