import Foundation
import XCTest

/// Adaptive streaming on the Apple TV: the address and VLC options of each quality, the
/// relay passing only the server's HLS files, and older settings keeping the original.
final class TVStreamingQualityTests: XCTestCase {
  private let stream = URL(string: "http://127.0.0.1:50123/stream/secret")!

  func testOriginalPlaysTheStreamAndTheOthersItsMasterPlaylist() {
    XCTAssertEqual(TVStreamingQuality.original.playbackURL(for: stream), stream)
    XCTAssertEqual(
      TVStreamingQuality.automatic.playbackURL(for: stream).absoluteString,
      "http://127.0.0.1:50123/stream/secret/hls/master.m3u8")
    XCTAssertEqual(TVStreamingQuality.original.vlcOptions, [":network-caching=500"])
    XCTAssertEqual(TVStreamingQuality.automatic.vlcOptions, [":network-caching=1500"])
    XCTAssertEqual(
      TVStreamingQuality.p480.vlcOptions,
      [":network-caching=1500", ":adaptive-maxheight=480", ":adaptive-logic=highest"])
    XCTAssertEqual(TVStreamingQuality.p720.effective(serverSupports: false), .original)
    XCTAssertEqual(TVStreamingQuality.p720.effective(serverSupports: true), .p720)
  }

  func testSettingsSavedBeforeTheChoiceExistedKeepTheOriginal() throws {
    var preferences = TVPlaybackPreferences.defaultValue
    var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as! [String: Any]
    old.removeValue(forKey: "streamingQuality")
    XCTAssertEqual(
      try JSONDecoder().decode(TVPlaybackPreferences.self, from: JSONSerialization.data(withJSONObject: old))
        .streamingQuality, .original)
    preferences.streamingQuality = .automatic
    XCTAssertEqual(
      try JSONDecoder().decode(TVPlaybackPreferences.self, from: JSONEncoder().encode(preferences)).streamingQuality,
      .automatic)
    old["streamingQuality"] = "8k"
    XCTAssertEqual(
      try JSONDecoder().decode(TVPlaybackPreferences.self, from: JSONSerialization.data(withJSONObject: old))
        .streamingQuality, .original)
  }

  func testTheRelayPassesOnlyTheServersHLSFiles() throws {
    func request(_ path: String) throws -> TVRelayRequest {
      try TVRelayRequest.parse(Data("GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:50123\r\n\r\n".utf8), secret: "secret")
    }
    XCTAssertEqual(try request("/stream/secret/hls/master.m3u8").hlsPath, "hls/master.m3u8")
    XCTAssertEqual(try request("/stream/secret/hls/720p/index.m3u8?audio=2").hlsPath, "hls/720p/index.m3u8?audio=2")
    XCTAssertEqual(try request("/stream/secret/hls/1080p/12.m4s").hlsPath, "hls/1080p/12.m4s")
    XCTAssertNil(try request("/stream/secret").hlsPath)
    for refused in [
      "/stream/other/hls/master.m3u8", "/stream/secret/hls/../../users", "/stream/secret/hls/720p/x.m4s",
      "/stream/secret/hls/720p/index.m3u8?audio=1&video=copy", "/stream/secret/live",
    ] {
      XCTAssertThrowsError(try request(refused), refused)
    }
    let source = URL(string: "https://server.test:43111/api/v1/streams/ticket-1")!
    XCTAssertEqual(
      TVRelayRequest.hlsURL("hls/720p/3.m4s?audio=1", below: source)?.absoluteString,
      "https://server.test:43111/api/v1/streams/ticket-1/hls/720p/3.m4s?audio=1")
    XCTAssertNil(TVRelayRequest.hlsURL("hls/../secret", below: source))
  }
}
