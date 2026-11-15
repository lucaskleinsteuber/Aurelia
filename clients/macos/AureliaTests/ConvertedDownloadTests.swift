import Foundation
import XCTest

@testable import Aurelia

/// Smaller downloads on the Mac ("converted-downloads-v1"): which quality a download takes, how
/// its pieces are fetched, and when it waits or gives up.
final class ConvertedDownloadTests: XCTestCase {
  private func options(_ ids: [String], canConvert: Bool = true) -> DownloadOptionsResponse {
    DownloadOptionsResponse(
      originalBytes: 54_000_000_000, durationSeconds: 7200, canConvert: canConvert,
      qualities: ids.map {
        DownloadQualityOption(id: $0, width: 0, height: 0, estimatedBytes: 1_800_000_000, estimatedSeconds: 1200)
      },
      audioTracks: [], audioTrack: 1)
  }

  func testTheSettingPicksTheQualityOrTheNextSmallerOne() {
    let all = options(["1080p", "720p", "480p", "360p"])
    XCTAssertEqual(DownloadQualityPreference.resolve("ask", options: all), .ask)
    XCTAssertEqual(DownloadQualityPreference.resolve("original", options: all), .original)
    XCTAssertEqual(DownloadQualityPreference.resolve("720p", options: all), .converted("720p"))
    // A small original has only the smaller qualities: 1080p wanted gives the best one there is.
    XCTAssertEqual(DownloadQualityPreference.resolve("1080p", options: options(["480p", "360p"])), .converted("480p"))
    XCTAssertEqual(DownloadQualityPreference.resolve("480p", options: options(["1080p", "720p"])), .converted("720p"))
    // Nothing smaller, an old server or no conversion: the original, without asking.
    XCTAssertEqual(DownloadQualityPreference.resolve("ask", options: options([])), .original)
    XCTAssertEqual(DownloadQualityPreference.resolve("720p", options: nil), .original)
    XCTAssertEqual(DownloadQualityPreference.resolve("720p", options: options(["720p"], canConvert: false)), .original)
  }

  func testPiecesComeFromTheQualitysPlaylistInOrder() {
    let playlist = "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4?audio=1\"\n#EXTINF:4.000,\n0.m4s?audio=1\n#EXTINF:4.000,\n1.m4s?audio=1\n#EXTINF:2.500,\n2.m4s?audio=1\n#EXT-X-ENDLIST\n"
    XCTAssertEqual(ConvertedDownloadPlan.segmentCount(playlist: playlist), 3)
    XCTAssertEqual(
      ConvertedDownloadPlan.piecePath(streamPath: "/api/v1/streams/abc", quality: "720p", piece: "3.m4s", audio: 1),
      "/api/v1/streams/abc/hls/720p/3.m4s?audio=1&purpose=download")
    XCTAssertEqual(
      ConvertedDownloadPlan.piecePath(streamPath: "/api/v1/streams/abc", quality: "480p", piece: "init.mp4", audio: nil),
      "/api/v1/streams/abc/hls/480p/init.mp4?purpose=download")
  }

  func testABusyServerIsWaitedForAndOtherAnswersEndTheDownload() {
    XCTAssertEqual(ConvertedDownloadPlan.retryDelay(status: 429, retryAfter: 5, attempt: 0), 5)
    XCTAssertEqual(ConvertedDownloadPlan.retryDelay(status: 429, retryAfter: nil, attempt: 9), 5)
    XCTAssertEqual(ConvertedDownloadPlan.retryDelay(status: 503, retryAfter: 600, attempt: 0), 60)
    XCTAssertEqual(ConvertedDownloadPlan.retryDelay(status: nil, retryAfter: nil, attempt: 3), 8)
    XCTAssertNil(ConvertedDownloadPlan.retryDelay(status: nil, retryAfter: nil, attempt: 8))
    XCTAssertNil(ConvertedDownloadPlan.retryDelay(status: 403, retryAfter: nil, attempt: 0))
    XCTAssertNil(ConvertedDownloadPlan.retryDelay(status: 409, retryAfter: nil, attempt: 0))
  }

  func testTheChoiceShowsSizeAndTime() throws {
    XCTAssertEqual(DownloadText.size(54_000_000_000), "54 GB")
    XCTAssertEqual(DownloadText.size(1_840_000_000), "1.8 GB")
    XCTAssertEqual(DownloadText.size(640_000_000), "640 MB")
    XCTAssertEqual(DownloadText.time(1200), "about 20 min")
    XCTAssertEqual(DownloadText.time(6000), "about 1 h 40 min")
    XCTAssertEqual(DownloadText.detail(options(["720p"]).qualities[0]), "About 1.8 GB · the server needs about 20 min")
    let json = #"{"originalBytes":100,"durationSeconds":null,"canConvert":false,"qualities":[],"audioTracks":[{"index":1,"format":"ac3","channels":6,"language":"eng","title":null,"isDefault":true,"mode":"aac","codec":"mp4a.40.2"}],"audioTrack":1}"#
    let decoded = try JSONDecoder().decode(DownloadOptionsResponse.self, from: Data(json.utf8))
    XCTAssertTrue(DownloadText.audio(decoded.audioTracks[0]).hasSuffix("· 5.1"))
  }
}
