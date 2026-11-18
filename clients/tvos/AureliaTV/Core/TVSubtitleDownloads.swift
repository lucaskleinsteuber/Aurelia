import Foundation

// Subtitles from OpenSubtitles for one title, for administrators (as on the Mac, the iPhone and in
// the browser): what was downloaded, a search by language, and downloading or removing one.

struct TVSubtitleCandidate: Codable, Identifiable, Equatable, Sendable {
  let fileId: String
  let language: String
  let release: String?
  let hashMatch: Bool
  let hearingImpaired: Bool
  let foreignPartsOnly: Bool
  let machineTranslated: Bool
  let downloadCount: Int
  let fromTrusted: Bool
  var id: String { fileId }

  /// "Matches this file · SDH · 1,204 downloads", the facts that help choose one.
  var details: String {
    var parts: [String] = []
    if hashMatch { parts.append("Matches this file") }
    if hearingImpaired { parts.append("SDH") }
    if foreignPartsOnly { parts.append("Foreign parts only") }
    if machineTranslated { parts.append("Machine translated") }
    if fromTrusted { parts.append("Trusted") }
    parts.append("\(downloadCount.formatted()) downloads")
    return parts.joined(separator: " · ")
  }

  var download: TVDownloadSubtitleRequest {
    TVDownloadSubtitleRequest(
      fileId: fileId, language: language, release: release, hearingImpaired: hearingImpaired,
      foreignPartsOnly: foreignPartsOnly)
  }
}

struct TVDownloadSubtitleRequest: Codable, Equatable, Sendable {
  let fileId: String
  let language: String
  let release: String?
  let hearingImpaired: Bool
  let foreignPartsOnly: Bool
}

struct TVDownloadedSubtitle: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let language: String
  let title: String
  let hearingImpaired: Bool
  let forced: Bool
  let provider: String
  let release: String?
  let automatic: Bool
}

enum TVSubtitleLanguages {
  static let choices = [
    "en", "de", "fr", "es", "it", "nl", "pt", "sv", "da", "no", "fi", "pl", "cs", "tr", "ru", "ja",
    "ko", "zh", "ar",
  ]

  static func name(_ code: String) -> String {
    Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
  }

  /// A sound track's tag ("ger", "deu", "en") as a two-letter code.
  static func code(forTrack tag: String?) -> String? {
    guard let tag = tag?.lowercased(), !tag.isEmpty, tag != "und" else { return nil }
    if tag.count == 2 { return tag }
    let known: [String: String] = [
      "eng": "en", "ger": "de", "deu": "de", "fre": "fr", "fra": "fr", "spa": "es", "ita": "it",
      "dut": "nl", "nld": "nl", "por": "pt", "swe": "sv", "dan": "da", "nor": "no", "nob": "no",
      "fin": "fi", "pol": "pl", "cze": "cs", "ces": "cs", "tur": "tr", "rus": "ru", "jpn": "ja",
      "kor": "ko", "chi": "zh", "zho": "zh", "ara": "ar",
    ]
    return known[tag]
  }

  /// The language to search first: the provider's first choice, else English.
  static func first(_ status: TVSubtitleProvider?) -> String {
    status?.languages.first(where: choices.contains) ?? "en"
  }
}

extension TVAPIClient {
  private static func subtitlesPath(_ id: UUID) -> String {
    "/api/v1/media/\(id.uuidString.lowercased())/subtitles"
  }

  func downloadedSubtitles(id: UUID) async throws -> [TVDownloadedSubtitle] {
    try Self.decodeAdmin(
      [TVDownloadedSubtitle].self, data: await adminData(Self.subtitlesPath(id)))
  }

  func searchSubtitles(id: UUID, language: String) async throws -> [TVSubtitleCandidate] {
    try Self.decodeAdmin(
      [TVSubtitleCandidate].self,
      data: await adminData(
        Self.subtitlesPath(id) + "/search",
        query: [URLQueryItem(name: "language", value: language)], longRunning: true))
  }

  func downloadSubtitle(id: UUID, _ request: TVDownloadSubtitleRequest) async throws
    -> TVDownloadedSubtitle
  {
    try Self.decodeAdmin(
      TVDownloadedSubtitle.self,
      data: await adminData(
        Self.subtitlesPath(id), method: "POST", body: JSONEncoder().encode(request),
        longRunning: true))
  }

  func removeSubtitle(id: UUID, subtitle: UUID) async throws {
    _ = try await adminData(
      Self.subtitlesPath(id) + "/\(subtitle.uuidString.lowercased())", method: "DELETE")
  }
}
