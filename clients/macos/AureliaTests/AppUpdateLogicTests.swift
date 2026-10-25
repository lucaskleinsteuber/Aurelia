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
}
