import Foundation

enum ArtworkVariantRequest {
  static func width(for points: Double, scale: Double) -> Int {
    let pixels = max(1, points * scale)
    return [320, 640, 1280, 1920].first { Double($0) >= pixels } ?? 1920
  }

  static func artwork(_ source: ArtworkSummary, width: Int?) -> ArtworkSummary {
    guard source.revision != nil, let width, [320, 640, 1280, 1920].contains(width),
      !source.path.contains("?")
    else { return source }
    return ArtworkSummary(
      id: source.id, kind: source.kind, path: source.path + "?width=\(width)",
      contentType: source.contentType, contentLength: source.contentLength,
      revision: source.revision)
  }
}
