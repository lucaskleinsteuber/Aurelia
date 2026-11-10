import Foundation
import XCTest

@testable import Aurelia

/// Adaptive streaming on the Mac: which address and VLC options each quality plays with, that
/// the relay passes only the server's HLS files, and that older settings keep the original.
final class StreamingQualityTests: XCTestCase {
  private let stream = URL(string: "http://127.0.0.1:50123/stream/secret")!

  func testOriginalPlaysTheStreamAndTheOthersItsMasterPlaylist() {
    XCTAssertEqual(StreamingQuality.original.playbackURL(for: stream), stream)
    XCTAssertEqual(
      StreamingQuality.automatic.playbackURL(for: stream).absoluteString,
      "http://127.0.0.1:50123/stream/secret/hls/master.m3u8")
    XCTAssertEqual(
      StreamingQuality.p720.playbackURL(for: stream).absoluteString,
      "http://127.0.0.1:50123/stream/secret/hls/master.m3u8")
    XCTAssertEqual(StreamingQuality.original.vlcOptions, [])
    XCTAssertEqual(StreamingQuality.automatic.vlcOptions, [":network-caching=1500"])
    XCTAssertEqual(
      StreamingQuality.p720.vlcOptions,
      [":network-caching=1500", ":adaptive-maxheight=720", ":adaptive-logic=highest"])
    XCTAssertEqual(StreamingQuality.p480.maximumHeight, 480)
  }

  func testAServerWithoutAdaptiveStreamingAlwaysPlaysTheOriginal() {
    XCTAssertEqual(StreamingQuality.p720.effective(serverSupports: false), .original)
    XCTAssertEqual(StreamingQuality.p720.effective(serverSupports: true), .p720)
  }

  func testSettingsSavedBeforeTheChoiceExistedKeepTheOriginalAndTheChoiceIsSaved() throws {
    var preferences = PlaybackPreferences.defaultValue
    var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as! [String: Any]
    old.removeValue(forKey: "streamingQuality")
    let decoded = try JSONDecoder().decode(
      PlaybackPreferences.self, from: JSONSerialization.data(withJSONObject: old))
    XCTAssertEqual(decoded.streamingQuality, .original)

    preferences.streamingQuality = .p480
    let saved = try JSONDecoder().decode(PlaybackPreferences.self, from: JSONEncoder().encode(preferences))
    XCTAssertEqual(saved.streamingQuality, .p480)

    old["streamingQuality"] = "8k"
    let unknown = try JSONDecoder().decode(
      PlaybackPreferences.self, from: JSONSerialization.data(withJSONObject: old))
    XCTAssertEqual(unknown.streamingQuality, .original)
  }

  func testTheRelayPassesOnlyTheServersHLSFiles() throws {
    func request(_ path: String) throws -> RelayRequest {
      try LoopbackStreamRelay.parseRequest(
        Data("GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:50123\r\n\r\n".utf8), secret: "secret")
    }
    XCTAssertEqual(try request("/stream/secret/hls/master.m3u8").hlsPath, "hls/master.m3u8")
    XCTAssertEqual(try request("/stream/secret/hls/720p/index.m3u8?audio=2").hlsPath, "hls/720p/index.m3u8?audio=2")
    XCTAssertEqual(try request("/stream/secret/hls/720p/init.mp4").hlsPath, "hls/720p/init.mp4")
    XCTAssertEqual(try request("/stream/secret/hls/1080p/1234.m4s?audio=1").hlsPath, "hls/1080p/1234.m4s?audio=1")
    XCTAssertNil(try request("/stream/secret").hlsPath)

    for refused in [
      "/stream/other/hls/master.m3u8", "/stream/secret/hls/../../users", "/stream/secret/hls/720p/x.m4s",
      "/stream/secret/hls/720p/index.m3u8?audio=1&video=copy", "/stream/secret/live", "/stream/secret/hls/720p/%2e%2e/init.mp4",
      "/stream/secret/hls/0p/index.m3u8", "/stream/secret/subtitles/1",
    ] {
      XCTAssertThrowsError(try request(refused), refused)
    }
  }

  func testHLSPathsLandBelowTheTicketsStreamOnTheServer() {
    let source = URL(string: "https://server.test:43111/api/v1/streams/ticket-1")!
    XCTAssertEqual(
      LoopbackStreamRelay.hlsURL("hls/720p/3.m4s?audio=1", below: source)?.absoluteString,
      "https://server.test:43111/api/v1/streams/ticket-1/hls/720p/3.m4s?audio=1")
    XCTAssertEqual(
      LoopbackStreamRelay.hlsURL("hls/master.m3u8", below: source)?.absoluteString,
      "https://server.test:43111/api/v1/streams/ticket-1/hls/master.m3u8")
    XCTAssertNil(LoopbackStreamRelay.hlsURL("hls/../secret", below: source))
  }
}

final class TranscodingStatusTests: XCTestCase {
  func testTheOwnerReadsTheEncoderAndEachConversion() throws {
    let json = Data(
      """
      {"available":true,"encoder":"vaapi","encoderName":"VA-API","device":"/dev/dri/renderD128","hardwareDecoding":true,
       "hardwareResting":false,"runningConversions":1,"videoLimit":3,"hint":null,
       "sessions":[{"title":"Invented Film.mkv","quality":"720p","encoder":"vaapi","speed":4.25,"converting":true},
                   {"title":"Invented Show.mkv","quality":"480p","encoder":null,"speed":null,"converting":false}]}
      """.utf8)
    let status = try JSONDecoder().decode(TranscodingStatus.self, from: json)
    XCTAssertEqual(status.encoderSummary, "VA-API (renderD128) · decodes on the chip")
    XCTAssertEqual(status.sessions.map(TranscodingStatus.sessionSummary), ["720p · 4.2× real time", "480p · ready"])
  }
}
