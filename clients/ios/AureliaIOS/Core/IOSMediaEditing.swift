import CoreGraphics
import Foundation

// A title's editor for administrators (Edit…), the same documents the Mac app and the browser
// edit: metadata, artwork, the video file, subtitles from OpenSubtitles or speech, and intro and
// credits times. Manual changes survive scans and provider refreshes.

struct IOSEditorCrop: Codable, Equatable, Sendable {
  var x: Double
  var y: Double
  var width: Double
  var height: Double
  var rotation: Int = 0
}

struct IOSEditorArtwork: Codable, Equatable, Sendable {
  var assetId: UUID?
  var uploadId: UUID?
  var crop: IOSEditorCrop?
}

struct IOSEditorCredit: Codable, Equatable, Identifiable, Sendable {
  var id: UUID
  var name: String
  var department: String
  var job: String?
  var character: String?
  var profile: IOSEditorArtwork?
  var personKey: String? = nil

  /// "as Captain Invented" or the job, for the list.
  var role: String {
    if let character, !character.isEmpty { return "as \(character)" }
    if let job, !job.isEmpty { return job }
    return department
  }
}

struct IOSMediaEditorValues: Codable, Equatable, Sendable {
  var title = ""
  var releaseYear: Int?
  var overview: String?
  var runtimeMinutes: Int?
  var fskAge: Int?
  var genres: [String] = []
  var studios: [String] = []
  var country: String?
  var credits: [IOSEditorCredit] = []
  var poster: IOSEditorArtwork?
  var backdrop: IOSEditorArtwork?
}

struct IOSMediaEditorDocument: Codable, Equatable, Sendable {
  let mediaId: UUID
  let libraryId: UUID
  let kind: IOSMediaKind
  let revision: Int64
  let values: IOSMediaEditorValues
  let overrideFields: [String]
  let sourcePath: String
  let relativeSourcePath: String
  let automaticValues: IOSMediaEditorValues
}

struct IOSSaveMediaEditorRequest: Codable, Equatable, Sendable {
  let revision: Int64
  let values: IOSMediaEditorValues
  let overrideFields: [String]
  let relativeSourcePath: String?
}

struct IOSServerFileEntry: Codable, Identifiable, Equatable, Sendable {
  let name: String
  let relativePath: String
  let isDirectory: Bool
  let bytes: Int64?
  var id: String { relativePath }
}

struct IOSServerFileListing: Codable, Equatable, Sendable {
  let libraryId: UUID
  let relativePath: String
  let entries: [IOSServerFileEntry]
}

/// The editor's draft: what changed, which fields keep a manual value and whether it may be saved.
struct IOSMetadataDraft: Equatable, Sendable {
  static let ageRatings = [0, 6, 12, 16, 18]
  static let departments = ["Acting", "Directing", "Writing", "Production", "Sound", "Camera"]

  private(set) var document: IOSMediaEditorDocument?
  var values = IOSMediaEditorValues()
  private(set) var overrides: Set<String> = []
  var year = ""
  var runtime = ""
  /// A newly chosen video file, relative to the storage location.
  var source: String?
  /// Uploaded pictures not saved yet; they are discarded when the editor closes without saving.
  var uploads: [UUID] = []

  init(document: IOSMediaEditorDocument? = nil) {
    if let document { load(document) }
  }

  mutating func load(_ document: IOSMediaEditorDocument) {
    self.document = document
    values = document.values
    overrides = Set(document.overrideFields)
    year = document.values.releaseYear.map(String.init) ?? ""
    runtime = document.values.runtimeMinutes.map(String.init) ?? ""
    source = nil
  }

  var isDirty: Bool {
    guard let document else { return false }
    return values != document.values || overrides != Set(document.overrideFields)
      || source != nil || year != (document.values.releaseYear.map(String.init) ?? "")
      || runtime != (document.values.runtimeMinutes.map(String.init) ?? "")
  }

  var problems: [String: String] {
    var problems: [String: String] = [:]
    if values.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      problems["title"] = "Enter a title."
    }
    if !year.isEmpty, Int(year).map({ (1800...3000).contains($0) }) != true {
      problems["releaseYear"] = "Enter a year from 1800 to 3000, or leave it empty."
    }
    if !runtime.isEmpty, Int(runtime).map({ (1...14_400).contains($0) }) != true {
      problems["runtimeMinutes"] = "Enter 1–14,400 minutes, or leave it empty."
    }
    if values.credits.contains(where: { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }) {
      problems["credits"] = "Enter a name for every person, or remove the empty entry."
    }
    return problems
  }

  var canSave: Bool { document != nil && problems.isEmpty && isDirty }

  func isManual(_ field: String) -> Bool { overrides.contains(field) }

  /// Changes a value and keeps it as a manual one.
  mutating func set<Value>(
    _ key: WritableKeyPath<IOSMediaEditorValues, Value>, _ value: Value,
    field: String
  ) {
    values[keyPath: key] = value
    overrides.insert(field)
  }

  mutating func setYear(_ text: String) {
    year = String(text.filter(\.isNumber).prefix(4))
    values.releaseYear = Int(year)
    overrides.insert("releaseYear")
  }

  mutating func setRuntime(_ text: String) {
    runtime = String(text.filter(\.isNumber).prefix(5))
    values.runtimeMinutes = Int(runtime)
    overrides.insert("runtimeMinutes")
  }

  /// Adds a genre or studio once, whatever its case.
  mutating func add(
    _ text: String, to key: WritableKeyPath<IOSMediaEditorValues, [String]>,
    field: String
  ) {
    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty,
      !values[keyPath: key].contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame })
    else { return }
    values[keyPath: key].append(clean)
    overrides.insert(field)
  }

  /// Goes back to what the server found for this field.
  mutating func useAutomatic(_ field: String) {
    guard let automatic = document?.automaticValues else { return }
    switch field {
    case "title": values.title = automatic.title
    case "releaseYear":
      values.releaseYear = automatic.releaseYear
      year = automatic.releaseYear.map(String.init) ?? ""
    case "overview": values.overview = automatic.overview
    case "runtimeMinutes":
      values.runtimeMinutes = automatic.runtimeMinutes
      runtime = automatic.runtimeMinutes.map(String.init) ?? ""
    case "fsk": values.fskAge = automatic.fskAge
    case "genres": values.genres = automatic.genres
    case "studios": values.studios = automatic.studios
    case "country": values.country = automatic.country
    case "credits": values.credits = automatic.credits
    case "poster": values.poster = automatic.poster
    case "backdrop": values.backdrop = automatic.backdrop
    default: return
    }
    overrides.remove(field)
  }

  var request: IOSSaveMediaEditorRequest? {
    guard let document, problems.isEmpty else { return nil }
    var values = values
    values.title = values.title.trimmingCharacters(in: .whitespacesAndNewlines)
    values.overview = values.overview.flatMap {
      let clean = $0.trimmingCharacters(in: .whitespacesAndNewlines)
      return clean.isEmpty ? nil : clean
    }
    return IOSSaveMediaEditorRequest(
      revision: document.revision, values: values, overrideFields: overrides.sorted(),
      relativeSourcePath: source)
  }
}

// MARK: Subtitles

struct IOSSubtitleCandidate: Codable, Identifiable, Equatable, Sendable {
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

  var download: IOSDownloadSubtitleRequest {
    IOSDownloadSubtitleRequest(
      fileId: fileId, language: language, release: release, hearingImpaired: hearingImpaired,
      foreignPartsOnly: foreignPartsOnly)
  }
}

struct IOSDownloadSubtitleRequest: Codable, Equatable, Sendable {
  let fileId: String
  let language: String
  let release: String?
  let hearingImpaired: Bool
  let foreignPartsOnly: Bool
}

struct IOSDownloadedSubtitle: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let language: String
  let title: String
  let hearingImpaired: Bool
  let forced: Bool
  let provider: String
  let release: String?
  let automatic: Bool
}

enum IOSSubtitleLanguages {
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
  static func first(_ status: IOSSubtitleProvider?) -> String {
    status?.languages.first(where: choices.contains) ?? "en"
  }
}

// MARK: Subtitles from speech (server-speech-v1)

struct IOSMediaSpeechJob: Codable, Equatable, Sendable {
  let kind: String
  let language: String
  let state: String
  let progress: Double
  let pausedForPlayback: Bool
  let message: String?

  var isRunning: Bool { ["waiting", "listening", "saving"].contains(state) }

  /// "Listening… 40 %", "Waiting while someone watches" and the end states.
  var statusText: String {
    switch state {
    case "waiting": pausedForPlayback ? "Waiting while someone watches…" : "Waiting…"
    case "listening":
      pausedForPlayback
        ? "Paused while someone watches"
        : "Listening… \(Int((progress * 100).rounded())) %"
    case "saving": "Saving…"
    case "done": message ?? "Saved."
    case "alreadyInSync": message ?? "These subtitles already fit the speech."
    case "failed": message ?? "The server could not finish."
    default: message ?? "Stopped."
    }
  }
}

struct IOSMediaSpeechInfo: Codable, Equatable, Sendable {
  let available: Bool
  let modelReady: Bool
  let job: IOSMediaSpeechJob?

  var canListen: Bool { available && modelReady }
}

struct IOSStartSpeechRequest: Codable, Equatable, Sendable {
  /// "create" writes subtitles from speech, "sync" moves a subtitle track to fit it.
  let kind: String
  let language: String
  var audioIndex: Int? = nil
  var subtitleIndex: Int? = nil
}

struct IOSSpeechAudioTrack: Codable, Identifiable, Equatable, Sendable {
  let index: Int
  let codec: String
  let channels: Int
  let language: String?
  let title: String?
  let isDefault: Bool
  var id: Int { index }

  /// "German · 5.1 · Commentary".
  var label: String {
    var parts: [String] = []
    if let code = IOSSubtitleLanguages.code(forTrack: language) {
      parts.append(IOSSubtitleLanguages.name(code))
    } else {
      parts.append("Track \(index + 1)")
    }
    parts.append(channels >= 6 ? "5.1" : channels == 1 ? "Mono" : "Stereo")
    if let title, !title.isEmpty { parts.append(title) }
    return parts.joined(separator: " · ")
  }
}

struct IOSSpeechAudioTracksResponse: Codable, Equatable, Sendable {
  var durationSeconds: Double? = nil
  let tracks: [IOSSpeechAudioTrack]
}

// MARK: Intro and credits (media-segments-v2)

struct IOSMediaSegmentsDetail: Codable, Equatable, Sendable {
  let mediaId: UUID
  let analyzed: Bool
  let canAnalyze: Bool
  let introStartMilliseconds: Int64?
  let introEndMilliseconds: Int64?
  let introSource: String
  let creditsStartMilliseconds: Int64?
  let creditsSource: String

  /// "Found by the server", "From chapters", "Set by hand", "Not found" or, while the server has
  /// not looked at the title yet, "Not examined yet".
  static func sourceText(_ source: String, examined: Bool = true) -> String {
    switch source.lowercased() {
    case "detected": "Found by the server"
    case "chapters": "From chapters"
    case "manual": "Set by hand"
    default: examined ? "Not found" : "Not examined yet"
    }
  }
}

struct IOSSetMediaSegmentsRequest: Codable, Equatable, Sendable {
  let introStartMilliseconds: Int64?
  let introEndMilliseconds: Int64?
  let creditsStartMilliseconds: Int64?
}

/// Which part the trim editor sets.
enum IOSSegmentPart: String, Identifiable, Sendable {
  case intro, credits
  var id: String { rawValue }
  var title: String { self == .intro ? "Intro" : "Credits" }
}

/// The trim editor's rules, as on the Mac: the stretch its film strip shows and how a handle may
/// move. Times are milliseconds.
enum IOSSegmentTrim {
  /// The intro is looked for in the first 12 minutes (at most 40 %); the credits in the last ten.
  static func span(part: IOSSegmentPart, duration: Int64, start: Int64?, end: Int64?)
    -> ClosedRange<Int64>
  {
    guard duration > 0 else { return 0...1 }
    switch part {
    case .intro:
      let window = min(720_000, duration * 2 / 5)
      let upper = min(duration, max(window, (end ?? 0) + 60_000))
      return 0...max(upper, 1)
    case .credits:
      let lower = max(0, min(duration - 600_000, (start ?? duration) - 60_000))
      return lower...duration
    }
  }

  static func initial(part: IOSSegmentPart, span: ClosedRange<Int64>) -> (start: Int64, end: Int64)
  {
    switch part {
    case .intro: (span.lowerBound, min(span.upperBound, span.lowerBound + 30_000))
    case .credits: (max(span.lowerBound, span.upperBound - 60_000), span.upperBound)
    }
  }

  /// Keeps the start at least a second before the end and both inside the strip.
  static func clamp(start: Int64, end: Int64, span: ClosedRange<Int64>) -> (
    start: Int64, end: Int64
  ) {
    let end = min(max(end, span.lowerBound + 1_000), span.upperBound)
    let start = min(max(start, span.lowerBound), end - 1_000)
    return (start, end)
  }

  /// The seconds of the film strip's pictures, evenly across the span.
  static func frames(in span: ClosedRange<Int64>, count: Int) -> [Int] {
    guard count > 0 else { return [] }
    let length = Double(span.upperBound - span.lowerBound)
    return (0..<count).map { index in
      Int((Double(span.lowerBound) + length * (Double(index) + 0.5) / Double(count)) / 1_000)
    }
  }

  /// "4:15.3"
  static func label(_ milliseconds: Int64) -> String {
    let tenths = max(0, milliseconds) / 100
    let seconds = tenths / 10
    let base =
      seconds >= 3_600
      ? String(format: "%lld:%02lld:%02lld", seconds / 3_600, seconds / 60 % 60, seconds % 60)
      : String(format: "%lld:%02lld", seconds / 60, seconds % 60)
    return base + ".\(tenths % 10)"
  }
}

// MARK: Artwork upload

enum IOSEditorImage {
  static let maximumBytes = 20 * 1024 * 1024
  static let maximumPixels = 24_000_000
  /// Pictures are made smaller than this on their long side before upload; posters and backdrops
  /// never need more.
  static let longSide = 4_000

  /// The size a picture is uploaded in: at most `longSide` and 24 megapixels, the server's limit.
  static func uploadSize(width: Int, height: Int) -> (width: Int, height: Int) {
    guard width > 0, height > 0 else { return (0, 0) }
    var scale = min(1, Double(longSide) / Double(max(width, height)))
    let pixels = Double(width) * Double(height) * scale * scale
    if pixels > Double(maximumPixels) { scale *= (Double(maximumPixels) / pixels).squareRoot() }
    return (max(1, Int(Double(width) * scale)), max(1, Int(Double(height) * scale)))
  }

  static func scaled(_ image: CGImage) -> CGImage {
    let size = uploadSize(width: image.width, height: image.height)
    guard size.width != image.width || size.height != image.height,
      let context = CGContext(
        data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return image }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
    return context.makeImage() ?? image
  }
}
