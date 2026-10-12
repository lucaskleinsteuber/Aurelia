import Foundation

/// CLI companion to the synthetic-only generator; output is private setup metadata.
@main
@MainActor
struct FullChainFixtureGenerator {
  static func main() async throws {
    guard CommandLine.arguments.count == 2 else { throw Failure.invalidOwnedRoot }
    let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    guard root.path.contains("/Library/Caches/Aurelia/TestRuns/playback-evidence-"),
      root.lastPathComponent == "Fixtures", root.resolvingSymlinksInPath().path == root.path
    else { throw Failure.invalidOwnedRoot }
    let fixtures = try await FullChainSyntheticMedia.generate(in: root)
    let identifiers = [
      "AVI": "94EFCF84-939F-47A8-9D7C-6E0F494C2701",
      "MP4": "94EFCF84-939F-47A8-9D7C-6E0F494C2702",
      "MKV": "94EFCF84-939F-47A8-9D7C-6E0F494C2703",
    ]
    let manifest = fixtures.map { fixture in
      ["format": fixture.name, "mediaId": identifiers[fixture.name]!, "path": fixture.url.path]
    }
    let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
    try FileHandle.standardOutput.write(contentsOf: data)
  }
  enum Failure: Error { case invalidOwnedRoot }
}
